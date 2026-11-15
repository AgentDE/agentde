import AppKit
import AgentDEKit

/// Claude's sessions beyond one tab: forking a conversation into a new tab, and Claude's background sessions
/// (`/fork`, `claude --bg`): opening new ones as tabs, attaching restored tabs to live ones, stopping one when its
/// tab closes.
extension Store {
    /// Forks a tab's Claude conversation into a new tab beside it (`claude --resume <id> --fork-session`).
    func forkTab(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, let (g, t) = locate(id) else { return }
        let source = groups[g].tabs[t]
        guard source.runs(ClaudeAgent.id) || source.kind == .shell, let sessionId = source.agentSession else {
            let alert = NSAlert()
            alert.messageText = "No Claude session to fork"
            alert.informativeText = "Start Claude in this tab first. Forking copies its conversation into a new tab."
            alert.runModal()
            return
        }
        // A name for the fork (pre-filled; Settings → Terminal can skip asking): its tab, its Claude session and,
        // with Workstreams, its new workstream all take it.
        let suggested = title(for: source) + " (fork)"
        var name = suggested
        if settings.askSessionName {
            let alert = NSAlert()
            alert.messageText = "Name the fork"
            alert.informativeText = "A copy of \(title(for: source))'s conversation in a new tab. The name shows on the tab, in Recent and on its workstream."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.stringValue = suggested
            alert.accessoryView = field
            alert.addButton(withTitle: "Fork")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            if !typed.isEmpty { name = typed }
        }
        // The alert ran the event loop: find the source again.
        guard let (sg, st) = locate(source.id) else { return }
        var fork = TabModel.agent(ClaudeAgent.id, cwd: source.cwd, session: sessionId)
        fork.forkOnStart = true
        fork.customTitle = name
        fork.sessionName = name
        groups[sg].tabs.insert(fork, at: st + 1)
        selectTab(fork.id)
        scheduleSave()
        if let parent = tabInfo(source.id), let child = tabInfo(fork.id) {
            for ext in extensions { ext.tabForked(child, from: parent) }
        }
    }

    /// `notYet`: not a session to open as things stand (a spare, or no name yet); the monitor asks again each poll.
    enum BackgroundAdoption { case adopted, ignored, retryLater, notYet }

    /// Which background sessions get a tab: forks, and sessions with a name of their own. Not the daemon's spares,
    /// which are named after their job id until a resume or `--bg` claims them.
    static func opensAsTab(_ entry: ClaudeSessionEntry, isFork: () -> Bool) -> Bool {
        if entry.spare == true { return false }
        if let name = entry.name, !name.isEmpty, name != entry.jobId { return true }
        return isFork()
    }

    /// Where a new tab for a background session in `cwd` goes: after the most recently focused tab in that
    /// folder, else at the end of the group whose folder contains it. Nil when no group covers the folder.
    static func placement(forBackgroundIn cwd: String, groups: [GroupModel],
                          lastFocusedAt: [UUID: Date]) -> (group: Int, index: Int)? {
        var best: (group: Int, index: Int, at: Date)?
        for (g, group) in groups.enumerated() {
            for (t, tab) in group.tabs.enumerated() where tab.cwd == cwd {
                let at = lastFocusedAt[tab.id] ?? .distantPast
                if best == nil || at > best!.at { best = (g, t + 1, at) }
            }
        }
        if let best { return (best.group, best.index) }
        let folder = { (dir: String) in dir.hasSuffix("/") ? dir : dir + "/" }
        let owners = groups.indices.filter { cwd == groups[$0].dir || cwd.hasPrefix(folder(groups[$0].dir)) }
        guard let g = owners.max(by: { groups[$0].dir.count < groups[$1].dir.count }) else { return nil }
        return (g, groups[g].tabs.count)
    }

    /// Opens a new background Claude session (from `/fork`, or `claude --bg` run anywhere) as an ordinary tab
    /// that attaches to it, beside the last tab used in its folder (see `opensAsTab` for which ones).
    func adoptBackgroundSession(_ entry: ClaudeSessionEntry) -> BackgroundAdoption {
        guard let jobId = SafeID.job(entry.jobId), let cwd = entry.cwd,
              !groups.contains(where: { $0.tabs.contains { $0.attachJobId == jobId || $0.agentSession == entry.sessionId } })
        else { return .ignored }
        guard Store.opensAsTab(entry, isFork: { Store.forkParent(job: jobId) != nil }) else { return .notYet }
        guard let (g, index) = Store.placement(forBackgroundIn: cwd, groups: groups, lastFocusedAt: lastFocusedAt)
        else { return .ignored }
        DebugLog.log("opened background job \(jobId) (\(entry.name ?? "unnamed")) in a new tab in \(groups[g].name)", "agent")
        var tab = TabModel.agent(ClaudeAgent.id, cwd: cwd, session: entry.sessionId)
        tab.attachJobId = jobId
        tab.lastAgentName = entry.name
        groups[g].tabs.insert(tab, at: index)
        var rt = TabRuntime()
        rt.agentName = entry.name
        rt.sparkleToken = 1
        rt.sparkleAt = Date()
        runtime[tab.id] = rt
        if let info = tabInfo(tab.id) {
            let parent = Store.forkParent(job: jobId)
            for ext in extensions { ext.backgroundSessionOpened(info, session: entry.sessionId, forkParent: parent) }
        }
        NSSound(named: "Pop")?.play()
        scheduleSave()
        return .adopted
    }

    /// Live background sessions in Claude's registry, as session id → job id.
    static func liveBackgroundJobs(in sessionsDir: URL) -> [String: String] {
        var jobs: [String: String] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(ClaudeSessionEntry.self, from: data),
                  entry.kind == "bg", let session = entry.sessionId, let job = SafeID.job(entry.jobId),
                  kill(entry.pid, 0) == 0 else { continue }
            jobs[session] = job
        }
        return jobs
    }

    /// A restored Claude tab whose session is running as a background job attaches to that job rather than
    /// resuming a second live copy of the same conversation.
    func attachToLiveBackgroundJobs(_ jobsBySession: [String: String]) {
        for g in groups.indices {
            for t in groups[g].tabs.indices {
                let tab = groups[g].tabs[t]
                guard tab.runs(ClaudeAgent.id), tab.attachJobId == nil, let session = tab.agentSession,
                      let job = jobsBySession[session] else { continue }
                DebugLog.log("tab \(tab.id.uuidString.prefix(8)) attaches to background job \(job) instead of resuming its session", "agent")
                groups[g].tabs[t].attachJobId = job
                groups[g].tabs[t].forkOnStart = nil
            }
        }
    }

    /// Stops a background session (`claude stop`): its tab closed, so the agent ends too. The conversation is
    /// kept, so it can be resumed from the group's recent sessions. A failure only goes to the log.
    func stopBackgroundJob(_ job: String) {
        guard let job = SafeID.job(job) else { return }
        stoppingJobs.insert(job)
        // Interactive login shell, like the tabs, so `claude` is on PATH even when .zshrc puts it there.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lic", "claude stop \(job)"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        task.terminationHandler = { finished in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let last = text.split(separator: "\n").last.map(String.init) ?? ""
            DebugLog.log("claude stop \(job) exit \(finished.terminationStatus): \(last.prefix(200))", "agent")
            let failed = finished.terminationStatus != 0
            DispatchQueue.main.async { [weak self] in
                self?.stoppingJobs.remove(job)
                if failed { self?.failedStops.insert(job) } else { self?.failedStops.remove(job) }
            }
        }
        do { try task.run() } catch {
            DebugLog.log("couldn't run claude stop: \(error)", "agent")
            stoppingJobs.remove(job)
            failedStops.insert(job)
        }
    }
}
