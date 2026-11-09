import Foundation
import Testing
@testable import AgentDE

@Suite("Claude versions")
struct ClaudeVersionTests {
    @Test func readsTheVersionFromAnExecutablePath() {
        #expect(ClaudeVersion.parse(executablePath: "/Users/me/.local/share/claude/versions/2.1.318") == "2.1.318")
        #expect(ClaudeVersion.parse(executablePath: "/opt/claude/versions/2.2.0-beta.1/claude") == "2.2.0-beta.1")
        #expect(ClaudeVersion.parse(executablePath: "/opt/homebrew/bin/node") == nil)
        #expect(ClaudeVersion.parse(executablePath: "/x/versions/") == nil)
        #expect(ClaudeVersion.parse(executablePath: "/x/versions/latest") == nil)
        #expect(ClaudeVersion.parse(executablePath: "/x/versions/2.1.3; rm -rf ~") == nil)
    }

    @Test func readsTheVersionFromVersionOutput() {
        #expect(ClaudeVersion.parse(versionOutput: "2.1.319 (Claude Code)\n") == "2.1.319")
        #expect(ClaudeVersion.parse(versionOutput: "some shell noise\n2.1.319 (Claude Code)") == "2.1.319")
        #expect(ClaudeVersion.parse(versionOutput: "command not found: claude") == nil)
    }

    @Test func installedVersionFollowsTheLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-cv-\(UUID().uuidString)")
        let versions = dir.appendingPathComponent("share/claude/versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let binary = versions.appendingPathComponent("2.1.319")
        try Data().write(to: binary)
        let link = dir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        #expect(ClaudeVersion.installed(link: link) == "2.1.319")
    }

    @Test func runningVersionOfThisProcessIsUnknown() {
        // The test runner isn't under a versions folder, so it never counts as some Claude version.
        #expect(ClaudeVersion.running(pid: getpid()) == nil)
    }

    @Test func outdatedOnlyWhenBothAreKnownAndDiffer() {
        #expect(ClaudeVersion.isOutdated(running: "2.1.318", installed: "2.1.319"))
        #expect(!ClaudeVersion.isOutdated(running: "2.1.319", installed: "2.1.319"))
        #expect(!ClaudeVersion.isOutdated(running: nil, installed: "2.1.319"))
        #expect(!ClaudeVersion.isOutdated(running: "2.1.318", installed: nil))
        #expect(!ClaudeVersion.isOutdated(running: "", installed: "2.1.319"))
    }
}

@Suite("Restart Claude")
struct ClaudeRestartTests {
    let session = "6E6EBD7E-D01C-4352-ACFD-67B044CFC314"

    private func check(kind: TabKind = .claude, session: String? = "6e6ebd7e-d01c-4352-acfd-67b044cfc314",
                       present: Bool = true, pid: pid_t? = 42, state: AgentState = .none,
                       restarting: Bool = false) -> ClaudeRestart.Check {
        ClaudeRestart.check(kind: kind, sessionId: session, agentPresent: present, agentPid: pid,
                            state: state, restarting: restarting)
    }

    @Test func onlyIdleClaudeTabsAreEligible() {
        #expect(check() == .eligible)
        #expect(check(state: .doneUnseen) == .eligible)
        #expect(check(state: .working) == .working)
        #expect(check(state: .needsYou) == .needsYou)
        #expect(check(restarting: true) == .restarting)
    }

    @Test func needsAClaudeTabWithASessionAndARunningAgent() {
        #expect(check(kind: .shell) == .notClaude)
        #expect(check(kind: .codex) == .notClaude)
        #expect(check(session: nil) == .noSession)
        #expect(check(session: "x; rm -rf ~") == .noSession)
        #expect(check(present: false) == .noAgent)
        #expect(check(pid: nil) == .noAgent)
        #expect(check(pid: 0) == .noAgent)
    }

    @Test func backgroundTabsRestartTheirJob() {
        #expect(ClaudeRestart.mode(attachJobId: "6cf96e0e") == .background)
        #expect(ClaudeRestart.mode(attachJobId: nil) == .foreground)
        // An invalid job id never reaches a shell; the tab is treated as foreground.
        #expect(ClaudeRestart.mode(attachJobId: "6cf; echo") == .foreground)
    }

    @Test func foregroundResumeCommandUsesTheValidatedSessionId() {
        #expect(ClaudeRestart.resumeCommand(sessionId: session) == "claude --resume 6e6ebd7e-d01c-4352-acfd-67b044cfc314")
        #expect(ClaudeRestart.resumeCommand(sessionId: "6e6ebd7e; rm -rf ~") == nil)
        #expect(ClaudeRestart.resumeCommand(sessionId: nil) == nil)
    }

    @Test func backgroundCommandResumesInTheBackgroundWithAReceipt() throws {
        let command = try #require(ClaudeRestart.backgroundCommand(sessionId: session))
        #expect(command.contains("claude --bg --resume 6e6ebd7e-d01c-4352-acfd-67b044cfc314 2>&1"))
        #expect(command.contains("claude attach \"$_mf_id\""))
        #expect(command.contains("attach/$AGENTDE_TAB_ID"))
        #expect(!command.contains("--fork-session"))
        #expect(ClaudeRestart.backgroundCommand(sessionId: "x`id`") == nil)
    }

    /// The background restart's command in a real zsh, with a stand-in `claude`: it resumes the session in the
    /// background, records the new job id for the tab and attaches to it.
    @Test func backgroundCommandRunsAndAttachesToTheNewJob() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-rs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fake = """
        claude() {
          echo "CALLED: claude $*" >&2
          [[ $1 == --bg ]] && printf 'backgrounded · 1234abcd · project (idle)\\n'
          return 0
        }
        """
        let script = fake + "\n" + (try #require(ClaudeRestart.backgroundCommand(sessionId: session)))
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-f", "-c", script]
        zsh.environment = ["HOME": home.path, "AGENTDE_TAB_ID": "TAB-2", "PATH": "/usr/bin:/bin"]
        let err = Pipe()
        zsh.standardError = err
        zsh.standardOutput = FileHandle.nullDevice
        try zsh.run()
        zsh.waitUntilExit()
        let calls = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(calls.contains("CALLED: claude attach 1234abcd"))
        let receipt = try String(contentsOf: home.appendingPathComponent(".config/\(AppBrand.dataFolder)/attach/TAB-2"), encoding: .utf8)
        #expect(receipt.trimmingCharacters(in: .whitespacesAndNewlines) == "1234abcd")
    }

    @Test func summaryNamesWhatWasSkipped() {
        #expect(ClaudeRestart.summary(restarted: 9, busy: 3, failed: 0) == "Restarted 9, skipped 3 busy")
        #expect(ClaudeRestart.summary(restarted: 2, busy: 0, failed: 0) == "Restarted 2")
        #expect(ClaudeRestart.summary(restarted: 1, busy: 1, failed: 1) == "Restarted 1, skipped 1 busy, 1 didn't restart")
    }
}
