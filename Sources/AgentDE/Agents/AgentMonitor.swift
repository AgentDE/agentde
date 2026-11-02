import AppKit
import Darwin

/// One entry from Claude Code's live session registry (`~/.claude/sessions/<pid>.json`).
struct ClaudeSessionEntry: Decodable {
    var pid: Int32
    var sessionId: String?
    var name: String?
    var status: String?
    var cwd: String?
    /// "interactive" or "bg" (background session, e.g. from `/fork` or `claude --bg`).
    var kind: String?
    /// Background sessions' short id, the one `claude attach` takes.
    var jobId: String?
    /// Set while `status` is `waiting`: what the session needs from you.
    var waitingFor: String?
    /// A spare: an idle session Claude's daemon keeps started so the next resume or `--bg` is instant. It
    /// registers as a background session named after its job id.
    var spare: Bool?
}

/// Reads Claude's session registry, decoding only the files that changed since the last read.
final class SessionRegistryReader {
    private let dir: URL
    private var cache: [String: (modified: Date, size: Int, entry: ClaudeSessionEntry?)] = [:]
    /// Files decoded so far, for tests.
    private(set) var decodes = 0

    init(dir: URL) { self.dir = dir }

    /// Every registry entry, live or not (callers check the pid).
    func read() -> [ClaudeSessionEntry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        var entries: [ClaudeSessionEntry] = []
        var seen = Set<String>()
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: keys)
            let modified = values?.contentModificationDate ?? .distantPast, size = values?.fileSize ?? -1
            seen.insert(file.path)
            if let cached = cache[file.path], cached.modified == modified, cached.size == size {
                if let entry = cached.entry { entries.append(entry) }
                continue
            }
            decodes += 1
            let entry = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ClaudeSessionEntry.self, from: $0) }
            cache[file.path] = (modified, size, entry)
            if let entry { entries.append(entry) }
        }
        cache = cache.filter { seen.contains($0.key) }
        return entries
    }
}

/// Polls Claude Code's session registry and maps each live session onto the tab whose process tree contains it.
/// No hooks or configuration needed: Claude keeps the registry current itself.
final class AgentMonitor {
    private weak var store: Store?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "agentde.agent-monitor", qos: .utility)
    private let registry = SessionRegistryReader(dir: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions"))
    private let rateLimitsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/state/rate_limits.json")
    private var ticks = 0
    /// Background jobs already decided on. Jobs present at launch count as decided, so only sessions that
    /// appear while AgentDE runs can become tabs. Undecided ones are retried for up to 90 seconds.
    private var resolvedJobs: Set<String>?
    private var firstSeen: [String: Date] = [:]
    private let recentScanner = RecentSessionScanner()
    private let codexScanner = CodexSessionScanner()
    private let attachDir = URL(fileURLWithPath: AppBrand.configDirectory).appendingPathComponent("attach")

    /// What a tick needs from the main thread. The main thread refreshes it at the end of each tick, so the
    /// monitor never waits on the main thread (which can be busy drawing terminals).
    private struct Inputs {
        var shellPids: [pid_t: UUID] = [:]
        var showRecent = false
        var recentDays = 14.0
        var showCodex = false
    }
    private let inputsLock = NSLock()
    private var _inputs = Inputs()
    private var inputs: Inputs {
        get { inputsLock.lock(); defer { inputsLock.unlock() }; return _inputs }
        set { inputsLock.lock(); _inputs = newValue; inputsLock.unlock() }
    }
    /// Which tab's shell each Claude process descends from, kept until the tabs' shells change.
    private var owners: [pid_t: UUID?] = [:]
    private var ownersFor: [pid_t: UUID] = [:]

    init(store: Store) {
        self.store = store
    }

    /// Main thread only.
    private func refreshInputs(from store: Store) {
        inputs = Inputs(shellPids: store.terminals.shellPids, showRecent: store.settings.showRecentSessions,
                        recentDays: store.settings.recentSessionDays, showCodex: store.settings.showCodexSessions)
    }

    func start() {
        if let store { refreshInputs(from: store) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let inputs = self.inputs
        let shellPids = inputs.shellPids
        if shellPids != ownersFor { owners = [:]; ownersFor = shellPids }
        var matches: [UUID: ClaudeSessionEntry] = [:]
        var jobs: [String: ClaudeSessionEntry] = [:]
        var liveIds = Set<String>()
        var livePids = Set<pid_t>()
        for entry in registry.read() where kill(entry.pid, 0) == 0 {
            livePids.insert(entry.pid)
            if let id = entry.sessionId { liveIds.insert(id) }
            // Background sessions run under Claude's daemon, which lives in the process tree of whichever
            // tab's `claude` started it, so they're matched by job id, never by ancestry.
            if entry.kind == "bg" {
                if let job = entry.jobId { jobs[job] = entry }
            } else {
                let owner = owners[entry.pid] ?? owningTab(of: entry.pid, shellPids: shellPids)
                owners.updateValue(owner, forKey: entry.pid)   // "no owner" is remembered too
                if let owner { matches[owner] = entry }
            }
        }
        owners = owners.filter { livePids.contains($0.key) }
        // Job ids that background-mode tabs reported for themselves.
        // Receipts are written to `.tmp` and renamed, so a file here is complete. Each is left in place until
        // this instance confirms the tab is its own and the job id is valid (see Store.recordAttachedJob).
        var reported: [(UUID, String, URL)] = []
        for file in (try? FileManager.default.contentsOfDirectory(at: attachDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard file.pathExtension.isEmpty, let tab = UUID(uuidString: file.lastPathComponent) else { continue }
            let job = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(modified) > 86_400 {
                try? FileManager.default.removeItem(at: file)   // nobody claimed it in a day
            } else if let job = SafeID.job(job) {
                reported.append((tab, job, file))
            } else if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      Date().timeIntervalSince(modified) > 60 {
                try? FileManager.default.removeItem(at: file)   // unreadable and stale
            }
        }
        let backgroundBySession = Dictionary(jobs.values.compactMap { e in e.sessionId.map { ($0, e.jobId ?? "") } },
                                             uniquingKeysWith: { a, _ in a })
        if resolvedJobs == nil { resolvedJobs = Set(jobs.keys) }
        let newJobs = jobs.values.filter { !(resolvedJobs?.contains($0.jobId ?? "") ?? true) }
        for job in newJobs { if let id = job.jobId, firstSeen[id] == nil { firstSeen[id] = Date() } }
        // Ages are computed here, on the monitor queue that owns firstSeen, then handed to the main thread.
        let ages = Dictionary(newJobs.compactMap { job in job.jobId.map { ($0, Date().timeIntervalSince(firstSeen[$0] ?? Date())) } },
                              uniquingKeysWith: { a, _ in a })
        ticks += 1
        if ticks % 60 == 0 { DispatchQueue.main.async { [weak self] in self?.heartbeat() } }
        let limits = ticks % 15 == 1 ? readRateLimits() : nil
        let recent = inputs.showRecent && ticks % 30 == 1
            ? (recentScanner.scan(days: inputs.recentDays) + (inputs.showCodex ? codexScanner.scan(days: inputs.recentDays) : []))
                .sorted { $0.lastActive > $1.lastActive }
            : nil
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.store else { return }
            for (tab, job, file) in reported where store.recordAttachedJob(tab: tab, jobId: job) {
                try? FileManager.default.removeItem(at: file)
            }
            store.refreshActivePullRequest()
            if backgroundBySession != store.liveBackgroundJobs { store.liveBackgroundJobs = backgroundBySession }
            for job in newJobs.sorted(by: { ($0.jobId ?? "") < ($1.jobId ?? "") }) {
                guard let id = job.jobId else { continue }
                let outcome = store.adoptBackgroundSession(job)
                if outcome == .notYet { continue }   // asked again next poll
                if outcome != .retryLater || (ages[id] ?? 0) > 90 {
                    self?.resolve(id)
                }
            }
            store.applyClaudeSessions(matches, jobs: jobs, trackedTabs: Set(shellPids.values))
            if let limits, limits != store.rateLimits { store.rateLimits = limits }
            if let recent, recent != store.recentSessions { store.recentSessions = recent }
            store.updateLiveSessions(liveIds)
            self?.refreshInputs(from: store)
        }
    }

    private func resolve(_ job: String) {
        queue.async { [weak self] in
            self?.resolvedJobs?.insert(job)
            self?.firstSeen[job] = nil
        }
    }

    private var lastHeartbeat: (at: Date, cpu: Double)?

    /// Once a minute: memory, CPU over the last minute, live terminals, and any tab with heavy output.
    private func heartbeat() {
        guard let store else { return }
        let stats = DebugLog.processStats()
        let now = Date()
        let cpuPercent = lastHeartbeat.map { (stats.cpuSeconds - $0.cpu) / now.timeIntervalSince($0.at) * 100 } ?? 0
        lastHeartbeat = (now, stats.cpuSeconds)
        let counts = store.terminals.takeOutputCounts()
        let busy = store.runtime.values.filter { $0.state == .working }.count
        var line = String(format: "rss=%.0fMB cpu=%.1f%% terminals=%d working=%d", stats.rssMB, cpuPercent, counts.count, busy)
        let heavy = counts.filter { $0.value > 500_000 }.sorted { $0.value > $1.value }
        for (id, bytes) in heavy.prefix(5) {
            let name = store.tab(id).map { store.title(for: $0) } ?? id.uuidString.prefix(8).description
            line += String(format: " | heavy output: %@ %.1fMB/min", name, Double(bytes) / 1_048_576)
        }
        // Shells this app started that no tab owns any more (they shouldn't exist; log them if they do).
        let owned = Set(store.terminals.shellPids.keys)
        var orphans = ProcessTree.ownChildren().filter { !owned.contains($0) }
        // Exited shells nobody collected: reap them rather than leave zombies.
        orphans.removeAll { ProcessTree.isZombie($0) && waitpid($0, nil, WNOHANG) == $0 }
        if !orphans.isEmpty { line += " | shells with no tab: " + orphans.map(String.init).joined(separator: ",") }
        DebugLog.log(line, "heartbeat")
    }

    private func owningTab(of pid: pid_t, shellPids: [pid_t: UUID]) -> UUID? {
        var current = pid
        for _ in 0..<12 {
            if let tab = shellPids[current] { return tab }
            guard let parent = parentPid(current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private func parentPid(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func readRateLimits() -> RateLimits? {
        guard let data = try? Data(contentsOf: rateLimitsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else { return nil }
        func pct(_ key: String) -> Double? {
            ((limits[key] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
        }
        return RateLimits(fiveHour: pct("five_hour"), sevenDay: pct("seven_day"))
    }
}
