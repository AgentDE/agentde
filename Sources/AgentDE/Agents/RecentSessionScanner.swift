import Foundation

/// A session you started and named that was active recently, offered as a one-click resume under its group.
struct RecentSession: Identifiable, Equatable, Codable {
    enum Agent: String, Codable { case claude, codex }
    var id: String { sessionId }
    let sessionId: String
    let name: String
    let cwd: String
    let lastActive: Date
    var agent: Agent = .claude
}

/// Finds recent Claude sessions you started and named, from their transcripts in `~/.claude/projects`.
///
/// "Yours" means started from the Claude CLI or desktop app (SDK and scripted runs are left out) and named:
/// a title you gave (`/rename`, or the desktop app's title), else the name Claude Code gave its background
/// job (`~/.claude/jobs/<id>/state.json`). Forks of another session are left out.
///
/// Only each file's first 64 KB (cwd, entrypoint) and last 256 KB (latest title) are read, and results are
/// cached by modification time, so rescans only touch files that changed.
final class RecentSessionScanner {
    private struct Parsed {
        let sessionId: String
        /// The title you gave it; nil when it has none (a background job's own name may stand in).
        let name: String?
        let cwd: String
    }

    private let projectsDir: URL
    private let jobsDir: URL

    init(projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
         jobsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/jobs")) {
        self.projectsDir = projectsDir
        self.jobsDir = jobsDir
    }

    /// Session id → its background job's name, for jobs that aren't forks of another session.
    func jobNames() -> [String: String] {
        var names: [String: String] = [:]
        for job in (try? FileManager.default.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: job.appendingPathComponent("state.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["forkParentSessionId"] == nil,
                  let session = object["sessionId"] as? String,
                  let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            names[session] = name
        }
        return names
    }
    /// Keyed by transcript path; valid while both the transcript and its custom-title sidecar are unchanged.
    private var cache: [String: (mtime: Date, sidecar: Date?, parsed: Parsed?)] = [:]
    /// Sessions started by people, not by scripts: SDK sessions (`sdk-py`, `sdk-ts`, `sdk-cli`) are left out.
    private let interactiveEntrypoints: Set<String> = ["cli", "claude-desktop"]

    func scan(days: Double) -> [RecentSession] {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        var results: [RecentSession] = []
        var seen = Set<String>()
        let jobs = jobNames()
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime >= cutoff else { continue }
                seen.insert(file.path)
                let parsed: Parsed?
                let sidecar = (try? file.deletingPathExtension().appendingPathComponent("custom-title.json")
                    .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let cached = cache[file.path], cached.mtime == mtime, cached.sidecar == sidecar {
                    parsed = cached.parsed
                } else {
                    parsed = parse(file)
                    cache[file.path] = (mtime, sidecar, parsed)
                }
                if let parsed, let name = parsed.name ?? jobs[parsed.sessionId] {
                    results.append(RecentSession(sessionId: parsed.sessionId, name: name, cwd: parsed.cwd, lastActive: mtime))
                }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return results.sorted { $0.lastActive > $1.lastActive }
    }

    private func parse(_ file: URL) -> Parsed? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // The folder and entrypoint come from the first user lines. A first prompt can be bigger than one read
        // (a long paste), so keep reading until a whole user line is in, up to 16 MB.
        var cwd: String?
        var entrypoint: String?
        var head = Data()
        var checked = 0
        while cwd == nil || entrypoint == nil, head.count < 16 << 20,
              let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            head += chunk
            let complete = head[checked..<(head.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? checked)]
            for line in lines(Data(complete)) where contains(line, "\"type\":\"user\"") {
                guard let object = json(line) else { continue }
                if cwd == nil { cwd = object["cwd"] as? String }
                if entrypoint == nil { entrypoint = object["entrypoint"] as? String }
                if cwd != nil, entrypoint != nil { break }
            }
            checked = complete.endIndex
        }
        if cwd == nil, let object = json(Data(head[checked...])) {  // a file whose last line has no newline
            cwd = object["cwd"] as? String
            entrypoint = entrypoint ?? object["entrypoint"] as? String
        }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let tail = (try? handle.readToEnd()) ?? Data()

        guard let cwd, let entrypoint, interactiveEntrypoints.contains(entrypoint) else { return nil }

        // Your title: the latest custom title in the tail, else the title sidecar.
        var custom: String?
        for line in lines(tail) where contains(line, "\"type\":\"custom-title\"") {
            if let t = json(line)?["customTitle"] as? String { custom = t }
        }
        let sessionId = file.deletingPathExtension().lastPathComponent
        let sidecar = file.deletingLastPathComponent().appendingPathComponent(sessionId).appendingPathComponent("custom-title.json")
        if let data = try? Data(contentsOf: sidecar),
           let title = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["customTitle"] as? String {
            custom = custom ?? title
        }
        let name = custom?.trimmingCharacters(in: .whitespaces)
        return Parsed(sessionId: sessionId, name: name?.isEmpty == false ? name : nil, cwd: cwd)
    }

    private func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"))
    }

    private func contains(_ line: Data, _ marker: String) -> Bool {
        line.range(of: Data(marker.utf8)) != nil
    }

    private func json(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }
}
