import Darwin
import Foundation

/// Which Claude Code version runs in each tab, and which is installed. Claude Code updates itself on disk
/// (`~/.local/share/claude/versions/<version>`, with `~/.local/bin/claude` linking to the current one), but a
/// running `claude` keeps the version it started with until it restarts.
enum ClaudeVersion {
    static let defaultLink = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/claude")

    /// `s` when it looks like a version ("2.1.319", "2.2.0-beta.1"), else nil.
    static func valid(_ s: String?) -> String? {
        guard let s, s.range(of: #"^[0-9]+(\.[0-9]+)+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return s
    }

    /// The version in an executable's path: the component after `versions`
    /// (`~/.local/share/claude/versions/2.1.319`, or a folder of that name with the binary inside).
    static func parse(executablePath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "versions"), i + 1 < parts.count else { return nil }
        return valid(parts[i + 1])
    }

    /// The version in `claude --version` output ("2.1.319 (Claude Code)").
    static func parse(versionOutput: String) -> String? {
        versionOutput.split(whereSeparator: { $0.isWhitespace }).lazy.compactMap { valid(String($0)) }.first
    }

    /// Outdated: both versions are known and differ. Unknown versions never count as outdated.
    static func isOutdated(running: String?, installed: String?) -> Bool {
        guard let running = valid(running), let installed = valid(installed) else { return false }
        return running != installed
    }

    /// The version a process runs, from its executable's path.
    static func running(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return parse(executablePath: String(cString: buffer))
    }

    /// The installed version: where the `claude` link points, else `claude --version` from a login shell
    /// (slow, so only as a fallback; call off the main thread).
    static func installed(link: URL = defaultLink) -> String? {
        if let version = parse(executablePath: link.resolvingSymlinksInPath().path) { return version }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "claude --version"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while task.isRunning, Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate(); return nil }
        return parse(versionOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

/// The rules for restarting a tab's Claude so it picks up the installed version, keeping its session.
enum ClaudeRestart {
    enum Check: Equatable {
        case eligible
        /// Not a Claude tab, or no valid session id to resume.
        case notClaude, noSession
        /// No Claude process running in the tab right now (a sleeping tab resumes on the new version anyway).
        case noAgent
        case working, needsYou
        case restarting
    }

    /// Foreground: `/exit`, then `claude --resume` in the same shell. Background: stop the job, then start
    /// a new background session resuming it, in a fresh shell, and attach the tab to it.
    enum Mode: Equatable { case foreground, background }

    /// Only idle agents restart: not working, not waiting on you, and not mid-restart.
    static func check(kind: TabKind, sessionId: String?, agentPresent: Bool, agentPid: pid_t?,
                      state: AgentState, restarting: Bool) -> Check {
        guard kind == .claude else { return .notClaude }
        guard SafeID.session(sessionId) != nil else { return .noSession }
        if restarting { return .restarting }
        guard agentPresent, (agentPid ?? 0) > 0 else { return .noAgent }
        switch state {
        case .working: return .working
        case .needsYou: return .needsYou
        case .none, .doneUnseen: return .eligible
        }
    }

    static func mode(attachJobId: String?) -> Mode {
        SafeID.job(attachJobId) != nil ? .background : .foreground
    }

    /// What a foreground restart types at the shell prompt: the same `claude --resume <id>` a resuming tab runs.
    static func resumeCommand(sessionId: String?) -> String? {
        guard let id = SafeID.session(sessionId) else { return nil }
        return TerminalSession.agentCommand(for: TabModel(kind: .claude, cwd: "", claudeSessionId: id))
    }

    /// What a background restart's fresh shell runs: the background launch (`claude --bg --resume <id>`, the
    /// receipt, `claude attach`), as for any background tab.
    static func backgroundCommand(sessionId: String?) -> String? {
        guard let id = SafeID.session(sessionId) else { return nil }
        return TerminalSession.agentCommand(for: TabModel(kind: .claude, cwd: "", claudeSessionId: id), background: true)
    }

    /// The bulk action's summary: "Restarted 9, skipped 3 busy".
    static func summary(restarted: Int, busy: Int, failed: Int) -> String {
        var parts = ["Restarted \(restarted)"]
        if busy > 0 { parts.append("skipped \(busy) busy") }
        if failed > 0 { parts.append("\(failed) didn't restart") }
        return parts.joined(separator: ", ")
    }
}
