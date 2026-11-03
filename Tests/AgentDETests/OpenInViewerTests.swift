import Foundation
import Testing
@testable import AgentDE

@Suite("open in the viewer", .serialized)
struct OpenInViewerTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-open-\(UUID().uuidString)")
    let tab = UUID()

    /// Runs the script in `root/work` with `arguments`; the real `open` is a stub that records what it got.
    func run(_ arguments: [String], inTab: Bool = true) throws -> (requests: [(tab: UUID, item: String, file: URL)], fallback: String) {
        let work = root.appendingPathComponent("work"), requests = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("open.sh"), fallback = root.appendingPathComponent("fallback.txt")
        try OpenInViewer.script(requests: requests).write(to: script, atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("real-open")
        try "#!/bin/sh\necho \"$*\" > '\(fallback.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        try? FileManager.default.removeItem(at: fallback)
        try? FileManager.default.removeItem(at: requests)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "AGENTDE_REAL_OPEN": stub.path]
            .merging(inTab ? ["AGENTDE_TAB_ID": tab.uuidString] : [:]) { $1 }
        try process.run()
        process.waitUntilExit()
        return (OpenInViewer.pending(in: requests), (try? String(contentsOf: fallback, encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? "")
    }

    @Test func aFileOrPageInATabGoesToItsViewer() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "<p>hi</p>".write(to: work.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)

        let relative = try run(["report.html"])
        #expect(relative.requests.map(\.tab) == [tab] && relative.fallback.isEmpty)
        #expect(relative.requests.first.map { ($0.item as NSString).lastPathComponent == "report.html" && $0.item.hasPrefix("/") } == true)

        let page = try run(["https://example.com/a"])
        #expect(page.requests.first?.item == "https://example.com/a")
    }

    @Test func everythingElseGoesToTheRealOpen() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work/folder"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("work/a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["-a", "Safari"], ["folder"], ["missing.txt"], ["a.txt", "a.txt"], ["mailto:me@example.com"]] {
            let result = try run(arguments)
            #expect(result.requests.isEmpty, "\(arguments)")
            #expect(result.fallback == arguments.joined(separator: " "), "\(arguments)")
        }
        let outside = try run(["a.txt"], inTab: false)
        #expect(outside.requests.isEmpty && outside.fallback == "a.txt")
    }

    @Test func oldRequestsAreDropped() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let old = requests.appendingPathComponent("\(tab.uuidString).1")
        try "/tmp/x".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        try "/tmp/y".write(to: requests.appendingPathComponent(".\(tab.uuidString).2"), atomically: true, encoding: .utf8)   // still being written
        #expect(OpenInViewer.pending(in: requests).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
