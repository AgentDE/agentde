import Foundation
import Testing
@testable import AgentDE

@Suite("Hook status")
struct HookStatusTests {
    @Test func linesParse() {
        #expect(HookStatus.parse("working 4242\n") == .init(state: "working", pid: 4242, detail: nil))
        #expect(HookStatus.parse("needs-you 4242 approve rm -rf build") == .init(state: "needs-you", pid: 4242, detail: "approve rm -rf build"))
        #expect(HookStatus.parse("idle 7")?.registryStatus == "idle")
        #expect(HookStatus.parse("working 7")?.registryStatus == "busy")
        #expect(HookStatus.parse("needs-you 7")?.registryStatus == "waiting")
        #expect(HookStatus.parse("working") == nil)
        #expect(HookStatus.parse("dancing 42") == nil)
        #expect(HookStatus.parse("working 1") == nil)
        #expect(HookStatus.parse("") == nil)
    }

    /// A live pid's report is read; a dead one's file is removed.
    @Test func readsLiveReportsAndDropsDeadOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = UUID(), dead = UUID()
        try "working \(getpid())\n".write(to: dir.appendingPathComponent(live.uuidString), atomically: true, encoding: .utf8)
        try "working 99999999\n".write(to: dir.appendingPathComponent(dead.uuidString), atomically: true, encoding: .utf8)
        let reports = HookStatus.read(dir)
        #expect(reports.keys.sorted { $0.uuidString < $1.uuidString } == [live])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(dead.uuidString).path))
    }

    /// The hook command, run the way an agent runs it (`sh -c`), writes the state and the agent's pid.
    @Test func hookCommandWritesTheStateWithTheCallersPid() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", HookStatus.hookCommand("needs-you")]
        task.environment = ["AGENTDE_STATUS_FILE": file.path]
        let input = Pipe()
        task.standardInput = input
        try task.run()
        input.fileHandleForWriting.write(Data(#"{"session_id": "019a5c3e-7b2d-7c41-9e1a-3f5d2b8c4e6a", "hook_event_name":"PermissionRequest"}"#.utf8))
        try input.fileHandleForWriting.close()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
        let report = HookStatus.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(report == .init(state: "needs-you", pid: getpid(), detail: nil, session: "019a5c3e-7b2d-7c41-9e1a-3f5d2b8c4e6a"))

        // Outside AgentDE (no variable) it does nothing and still succeeds.
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sh")
        outside.arguments = ["-c", HookStatus.hookCommand("working")]
        outside.environment = [:]
        outside.standardInput = FileHandle.nullDevice
        try outside.run()
        outside.waitUntilExit()
        #expect(outside.terminationStatus == 0)
    }

    /// scripts/register-agent-status.sh writes the app's own hook commands, adds them once, and removes only its own.
    @Test func registerScriptMatchesTheApp() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/register-agent-status.sh")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let hooksFile = home.appendingPathComponent("hooks.json")
        try #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#.write(to: hooksFile, atomically: true, encoding: .utf8)
        func run(_ args: [String]) throws {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = [script.path] + args
            task.environment = ["CODEX_HOME": home.path, "PATH": "/usr/bin:/bin"]
            task.standardOutput = Pipe()
            try task.run()
            task.waitUntilExit()
            #expect(task.terminationStatus == 0)
        }
        func hooks() throws -> [String: [[String: Any]]] {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile)) as? [String: Any]
            return json?["hooks"] as? [String: [[String: Any]]] ?? [:]
        }
        func commands(_ event: String) throws -> [String] {
            try (hooks()[event] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        }
        try run(["--yes"])
        try run(["--yes"])   // again: nothing added twice
        #expect(try commands("Stop") == ["say done", HookStatus.hookCommand("idle")])
        #expect(try commands("PermissionRequest") == [HookStatus.hookCommand("needs-you")])
        #expect(try commands("UserPromptSubmit") == [HookStatus.hookCommand("working")])
        try run(["--uninstall", "--yes"])
        #expect(try commands("Stop") == ["say done"])
        #expect(try hooks().keys.sorted() == ["Stop"])
    }
}
