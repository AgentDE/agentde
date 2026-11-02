import Foundation
import Testing
@testable import AgentDE

@Suite("Search matching")
struct SearchMatchTests {
    func entry(_ text: String) -> SearchEntry {
        SearchEntry(role: .you, text: text, lower: text.lowercased(), timestamp: nil, order: 0)
    }

    @Test func everyWordMustAppearInAnyOrder() {
        let terms = SearchMatch.terms("  Dashboard   PLAYTEST ")
        #expect(terms == ["dashboard", "playtest"])
        #expect(SearchMatch.matches(entry("the playtest dashboard is live"), terms))
        #expect(!SearchMatch.matches(entry("the playtest feed"), terms))
    }

    @Test func snippetsCenterOnTheFirstWord() {
        let text = String(repeating: "a", count: 200) + " needle " + String(repeating: "b", count: 200)
        let snippet = SearchMatch.snippet(text, ["needle"], radius: 10)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.contains("needle"))
        #expect(snippet.count < 40)
    }
}

@Suite("Transcript index")
struct TranscriptIndexTests {
    let projects = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-tests-\(UUID().uuidString)")
    let session = UUID().uuidString.lowercased()
    let cwd = "/tmp/project"

    func line(_ type: String, _ text: String) -> String {
        let content = type == "user" ? "\"\(text)\"" : "[{\"type\":\"text\",\"text\":\"\(text)\"}]"
        return "{\"type\":\"\(type)\",\"timestamp\":\"2026-10-14T10:00:00.000Z\",\"message\":{\"content\":\(content)}}\n"
    }

    func transcript() throws -> URL {
        let dir = projects.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(session + ".jsonl")
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    @Test func indexesPromptsAndRepliesIncrementally() throws {
        let url = try transcript()
        try (line("user", "find the gbdt eval") + line("assistant", "Here is the gbdt eval")).write(to: url, atomically: true, encoding: .utf8)
        let index = TranscriptIndex(projectsDir: projects)
        #expect(index.entries(sessionId: session, cwd: cwd).count == 2)

        // A half-written line is held back until it's complete, and nothing is read twice.
        let next = line("user", "and the playtest dashboard")
        try append(String(next.prefix(20)), to: url)
        #expect(index.entries(sessionId: session, cwd: cwd).count == 2)
        try append(String(next.dropFirst(20)), to: url)
        let entries = index.entries(sessionId: session, cwd: cwd)
        #expect(entries.count == 3)
        #expect(entries.map(\.role) == [.you, .claude, .you])
        #expect(entries.last?.text == "and the playtest dashboard")
    }

    @Test func skipsHarnessTextAndToolOutput() throws {
        let url = try transcript()
        let toolResult = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"secret output\"}]}}\n"
        try (line("user", "<command-name>/compact</command-name>") + toolResult + line("user", "real prompt"))
            .write(to: url, atomically: true, encoding: .utf8)
        let entries = TranscriptIndex(projectsDir: projects).entries(sessionId: session, cwd: cwd)
        #expect(entries.map(\.text) == ["real prompt"])
    }

    @Test func forgetsSessionsNoLongerSearched() throws {
        let url = try transcript()
        try line("user", "hello").write(to: url, atomically: true, encoding: .utf8)
        let index = TranscriptIndex(projectsDir: projects)
        _ = index.entries(sessionId: session, cwd: cwd)
        index.retainOnly(sessionIds: [])
        // Re-reading from scratch still yields each message exactly once.
        #expect(index.entries(sessionId: session, cwd: cwd).count == 1)
    }
}
