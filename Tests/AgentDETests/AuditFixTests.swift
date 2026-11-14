import Foundation
import Testing
@testable import AgentDE

@Suite("Audit fixes")
struct AuditFixTests {
    /// Send Path to Agent: relative to the receiving agent's folder only when the file is inside it.
    @Test func pathsAreRelativeToTheReceivingFolder() {
        #expect(Store.path("/repo/src/main.swift", relativeTo: "/repo") == "src/main.swift")
        #expect(Store.path("/repo/src/main.swift", relativeTo: "/repo/") == "src/main.swift")
        #expect(Store.path("/repo-worktrees/fix/src/main.swift", relativeTo: "/repo") == "/repo-worktrees/fix/src/main.swift")
        #expect(Store.path("/repository/a.txt", relativeTo: "/repo") == "/repository/a.txt")
    }

    /// The fast, exact part of resolving a link finds real files, also with sentence punctuation.
    @Test func exactLinkResolutionNeedsNoSpotlight() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("out/report.html"), atomically: true, encoding: .utf8)
        #expect(Store.resolveFileLinkExact("out/report.html.", relativeTo: [dir.path])?.lastPathComponent == "report.html")
        #expect(Store.resolveFileLinkExact("out/missing.html", relativeTo: [dir.path]) == nil)
        #expect(Store.trimmedLink("compare.html).") == "compare.html")
    }

    /// Search reads Codex threads: your prompts and the agent's replies, not its instructions or tool calls.
    @Test func codexLogsAreSearchable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-codex-\(UUID().uuidString)")
        let day = dir.appendingPathComponent("2026/11/10")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "01a1c586-61ae-7882-ae83-68d23697c4df"
        let lines = [
            #"{"timestamp":"2026-11-10T12:54:41.383Z","type":"session_meta","payload":{"id":"\#(id)"}}"#,
            #"{"timestamp":"2026-11-10T12:54:42.822Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are Codex"}]}}"#,
            #"{"timestamp":"2026-11-10T12:55:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"timestamp":"2026-11-10T12:55:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"rename the flaky test"}]}}"#,
            #"{"timestamp":"2026-11-10T12:55:09.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Renamed it to testRetriesOnce."}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: day.appendingPathComponent("rollout-2026-11-10T04-54-41-\(id).jsonl"), atomically: true, encoding: .utf8)
        let index = TranscriptIndex(projectsDir: dir, codexDir: dir)
        let entries = index.entries(sessionId: id, cwd: "/tmp", codex: true)
        #expect(entries.map(\.text) == ["rename the flaky test", "Renamed it to testRetriesOnce."])
        #expect(entries.map(\.role) == [.you, .codex])
    }

    /// A new Claude tab with a name starts `claude --name '<name>'`, safely quoted; a resume ignores it.
    @Test func namedSessionsStartWithTheirName() {
        var tab = TabModel(kind: .claude, cwd: "/tmp")
        tab.sessionName = "fix Andy's login; rm -rf /"
        #expect(TerminalSession.agentCommand(for: tab) == #"claude --name 'fix Andy'\''s login; rm -rf /'"#)
        tab.claudeSessionId = "3d4e5f6a-7b8c-4d9e-8f0a-1b2c3d4e5f6a"
        #expect(TerminalSession.agentCommand(for: tab) == "claude --resume 3d4e5f6a-7b8c-4d9e-8f0a-1b2c3d4e5f6a")
    }

    /// The filter's day runs from 4 AM to 4 AM, so a late night counts as the same day.
    @Test func aDayStartsAtFourInTheMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        func at(_ day: Int, _ hour: Int) throws -> Date { try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))) }
        #expect(Store.isToday(try at(9, 23), now: try at(10, 2), calendar: calendar))
        #expect(Store.isToday(try at(10, 5), now: try at(10, 20), calendar: calendar))
        #expect(!Store.isToday(try at(10, 3), now: try at(10, 5), calendar: calendar))
        #expect(!Store.isToday(try at(8, 20), now: try at(10, 12), calendar: calendar))
    }

    /// The sidebar search matches every word, in any field, ignoring case.
    @Test func sidebarSearchMatchesEveryWord() {
        #expect(Store.matches("login fix", ["Fix the login bug", "app"]))
        #expect(Store.matches("APP login", ["fix login", "app"]))
        #expect(!Store.matches("login deploy", ["fix login", "app"]))
        #expect(Store.matches("  ", ["anything"]))
    }

    /// A fork starts with its own name; a plain resume doesn't rename the session.
    @Test func forksStartWithTheirName() {
        var tab = TabModel(kind: .claude, cwd: "/tmp")
        tab.claudeSessionId = "4e5f6a7b-8c9d-4e0f-9a1b-2c3d4e5f6a7b"
        tab.forkOnStart = true
        tab.sessionName = "try the other seed"
        #expect(TerminalSession.agentCommand(for: tab) == "claude --resume 4e5f6a7b-8c9d-4e0f-9a1b-2c3d4e5f6a7b --fork-session --name 'try the other seed'")
        tab.forkOnStart = nil
        #expect(TerminalSession.agentCommand(for: tab) == "claude --resume 4e5f6a7b-8c9d-4e0f-9a1b-2c3d4e5f6a7b")
    }

    /// Slides, documents and spreadsheets go to the fast rendered page, not the in-app Quick Look view.
    @Test func officeFilesAreRenderedPages() {
        #expect(ViewerKind.of("/x/deck.pptx") == .office)
        #expect(ViewerKind.of("/x/Plan.DOCX") == .office)
        #expect(ViewerKind.of("/x/talk.key") == .office)
        #expect(ViewerKind.of("/x/archive.zip") == .other)
    }

    /// Opening or closing a folder in the File Explorer keeps the preview on the last file.
    @Test func selectingAFolderKeepsThePreviewedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-explorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let model = FileExplorerModel(root: dir.path, selection: file.path)
        #expect(model.previewed == file)
        model.selection = dir.appendingPathComponent("sub")
        #expect(model.previewed == file)
    }
}
