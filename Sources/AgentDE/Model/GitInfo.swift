import Foundation

/// Reads the current git branch for a directory straight from `.git`, including worktrees.
enum GitInfo {
    private static var cache: [String: (at: Date, branch: String?)] = [:]
    /// Callers aren't all on the main thread (and tests run in parallel), so the cache is locked.
    private static let lock = NSLock()

    /// Cached for 2 seconds: views call this while rendering, so it shouldn't touch the disk every frame.
    static func branch(at dir: String) -> String? {
        if let hit = lock.withLock({ cache[dir] }), Date().timeIntervalSince(hit.at) < 2 { return hit.branch }
        let branch = readBranch(at: dir)
        lock.withLock { cache[dir] = (Date(), branch) }
        return branch
    }

    private static func readBranch(at dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        for _ in 0..<12 {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                var headURL = git.appendingPathComponent("HEAD")
                if !isDir.boolValue, let pointer = try? String(contentsOf: git, encoding: .utf8),
                   let path = pointer.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
                    headURL = gitDir.appendingPathComponent("HEAD")
                }
                guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
                return String(trimmed.prefix(8))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}
