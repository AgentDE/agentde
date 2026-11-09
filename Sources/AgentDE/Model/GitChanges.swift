import Foundation

/// One changed file in a working tree, against HEAD.
struct GitChange: Equatable, Identifiable {
    /// Relative to the repository's top folder.
    var path: String
    /// Porcelain status letters: "M", "A", "D", "R", "??" (untracked), "U" (conflict).
    var status: String
    var added: Int?
    var removed: Int?
    var id: String { path }
}

/// One commit in the branch's recent history.
struct GitCommit: Equatable, Identifiable {
    var hash: String
    var subject: String
    var author: String
    var date: Date
    var id: String { hash }
}

/// What the side panel's Changes tab shows: `git status` with line counts from `git diff --numstat HEAD`, and
/// the last commits. Read-only: committing and pushing are the agent's job.
enum GitChanges {
    /// Parses `git status --porcelain=v1 -z` and `git diff --numstat -z HEAD`.
    static func parse(status: Data, numstat: Data) -> [GitChange] {
        var counts: [String: (Int?, Int?)] = [:]
        let stat = numstat.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < stat.count {
            let fields = stat[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            i += 1
            guard fields.count == 3 else { continue }
            var path = fields[2]
            if path.isEmpty, i + 1 < stat.count { path = stat[i + 1]; i += 2 }   // a rename: old path, then new
            counts[path] = (Int(fields[0]), Int(fields[1]))   // "-" for binary files: no count
        }
        var changes: [GitChange] = []
        let entries = status.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var j = 0
        while j < entries.count {
            let entry = entries[j]
            j += 1
            guard entry.count > 3 else { continue }
            let xy = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            if xy.contains("R") || xy.contains("C") { j += 1 }   // the old path follows
            let status: String
            if xy == "??" { status = "??" }
            else if xy.contains("U") || xy == "AA" || xy == "DD" { status = "U" }
            else { status = String(xy.first { $0 != " " } ?? "M") }
            let count = counts[path]
            changes.append(GitChange(path: path, status: status, added: count?.0, removed: count?.1))
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Parses `git log -z --format=%H%x1f%s%x1f%an%x1f%ct`.
    static func parseLog(_ data: Data) -> [GitCommit] {
        data.split(separator: 0).compactMap { record in
            let f = String(decoding: record, as: UTF8.self).trimmingCharacters(in: .newlines)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let seconds = TimeInterval(f[3]) else { return nil }
            return GitCommit(hash: f[0], subject: f[1], author: f[2], date: Date(timeIntervalSince1970: seconds))
        }
    }

    /// The repository's top folder, its changes and its last commits, or nil when `dir` isn't in a git
    /// repository. Blocking.
    static func load(in dir: String, commits: Int = 30) -> (root: String, changes: [GitChange], log: [GitCommit])? {
        guard let topData = run(["-C", dir, "rev-parse", "--show-toplevel"]) else { return nil }
        let top = String(decoding: topData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty, let status = run(["-C", top, "status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return nil }
        let numstat = run(["-C", top, "diff", "--numstat", "-z", "HEAD"]) ?? Data()
        let log = run(["-C", top, "log", "-z", "-n", String(commits), "--format=%H%x1f%s%x1f%an%x1f%ct"]) ?? Data()
        return (top, parse(status: status, numstat: numstat), parseLog(log))
    }

    /// The change as a unified diff: against HEAD, or the whole file when it's untracked. Blocking.
    static func diff(_ change: GitChange, root: String) -> String {
        let args = change.status == "??"
            ? ["-C", root, "diff", "--no-color", "--no-index", "--", "/dev/null", change.path]
            : ["-C", root, "diff", "--no-color", "HEAD", "--", change.path]
        return run(args, ok: [0, 1]).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A commit's message and diff. Blocking.
    static func show(_ commit: GitCommit, root: String) -> String {
        run(["-C", root, "show", "--no-color", "--stat", "--patch", commit.hash]).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func run(_ args: [String], ok: Set<Int32> = [0]) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return ok.contains(task.terminationStatus) ? data : nil
    }
}
