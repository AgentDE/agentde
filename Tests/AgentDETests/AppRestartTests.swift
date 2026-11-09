import Foundation
import Testing
@testable import AgentDE

@Suite("Restart")
struct AppRestartTests {
    /// When `open` launches nothing, the helper logs each try and then starts the executable itself.
    @Test func fallsBackToTheExecutableWhenOpenLaunchesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("started")
        let exe = dir.appendingPathComponent("Fake")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let log = dir.appendingPathComponent("agentde.log")

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A bundle that doesn't exist (open fails), a pid that's long gone, one try.
        helper.arguments = ["-c", AppRestart.relaunchScript, dir.appendingPathComponent("Missing.app").path, exe.path, "999999", log.path, "1"]
        try helper.run()
        helper.waitUntilExit()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { usleep(100_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect((try? String(contentsOf: log, encoding: .utf8))?.contains("open launched nothing (attempt 1)") == true)
    }
}
