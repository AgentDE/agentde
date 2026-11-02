import Foundation

/// Git worktrees for "New → Workstream…": each named piece of work gets its own branch and folder, kept
/// beside the repo (`~/git/app` → `~/git/app-worktrees/<name>`) so no tool inside the repo sees a second copy.
public enum Worktrees {
    /// A name that works as a branch, a folder and a tab name: letters, digits, `.`, `_` and `-`, starting
    /// with a letter or digit, at most 60 characters, and never `..` or ending in `.` or `.lock`.
    public static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,59}$"#, options: .regularExpression) != nil,
              !name.contains(".."), !name.hasSuffix("."), !name.hasSuffix(".lock") else { return nil }
        return name
    }

    public static func path(repoRoot: String, name: String) -> String {
        let root = URL(fileURLWithPath: repoRoot).standardizedFileURL
        return root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-worktrees")
            .appendingPathComponent(name).path
    }

    /// The top folder of the git repo holding `folder`, or nil when it isn't in one.
    public static func repoRoot(of folder: String) -> String? {
        let result = git(["-C", folder, "rev-parse", "--show-toplevel"])
        return result.status == 0 && !result.output.isEmpty ? result.output : nil
    }

    /// New work starts from the remote's default branch ("origin/main", say), when the repo has a remote.
    public static func baseBranch(repoRoot: String) -> String? {
        let result = git(["-C", repoRoot, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        return result.status == 0 && !result.output.isEmpty ? result.output : nil
    }

    /// Makes the worktree on a new branch `name`: from the remote's default branch after fetching it, or from
    /// what the repo has checked out when there's none (a fetch that fails, say offline, falls back to the
    /// last one fetched). The branch doesn't track it, so a plain `git push` can't go there. Returns the start
    /// point used, or git's message on failure. Takes a moment in a big repo, so call it off the main thread.
    public static func add(repoRoot: String, name: String) -> Result<String, WorktreeError> {
        let remote = baseBranch(repoRoot: repoRoot)
        if let remote { _ = git(["-C", repoRoot, "fetch", "--quiet", "origin", String(remote.dropFirst("origin/".count))]) }
        let base = remote.flatMap { git(["-C", repoRoot, "rev-parse", "--verify", "--quiet", $0 + "^{commit}"]).status == 0 ? $0 : nil } ?? "HEAD"
        let result = git(["-C", repoRoot, "worktree", "add", "--no-track", "-b", name, path(repoRoot: repoRoot, name: name), base])
        guard result.status == 0 else { return .failure(WorktreeError(message: result.output.isEmpty ? "git worktree add failed" : result.output)) }
        return .success(base)
    }

    public struct WorktreeError: Error { public let message: String }

    private static func git(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        // Never wait on a password prompt nobody can see: a fetch that needs one just fails.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = env["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
