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
        let index = TranscriptIndex(); let format = ClaudeTranscript(projectsDir: projects)
        #expect(index.entries(sessionId: session, cwd: cwd, format: format).count == 2)

        // A half-written line is held back until it's complete, and nothing is read twice.
        let next = line("user", "and the playtest dashboard")
        try append(String(next.prefix(20)), to: url)
        #expect(index.entries(sessionId: session, cwd: cwd, format: format).count == 2)
        try append(String(next.dropFirst(20)), to: url)
        let entries = index.entries(sessionId: session, cwd: cwd, format: format)
        #expect(entries.count == 3)
        #expect(entries.map(\.role) == [.you, .agent, .you])
        #expect(entries.last?.text == "and the playtest dashboard")
    }

    /// A transcript bigger than one read chunk (lines straddling the chunk edges, a huge tool-output line) is
    /// indexed in pieces with every message found once.
    @Test func readsBigTranscriptsInChunks() throws {
        let url = try transcript()
        var text = ""
        for i in 0..<20 { text += line("user", "message \(i)") + "{\"type\":\"tool\",\"blob\":\"" + String(repeating: "x", count: 500_000) + "\"}\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(UInt64(text.utf8.count) > TranscriptIndex.chunkBytes * 2)
        let entries = TranscriptIndex().entries(sessionId: session, cwd: cwd, format: ClaudeTranscript(projectsDir: projects))
        #expect(entries.map(\.text) == (0..<20).map { "message \($0)" })
    }

    /// A path or link finds the session that touched it in a tool call, even across a chunk boundary.
    @Test func pathsAndLinksAreFoundInRawTranscripts() throws {
        #expect(SearchMatch.locatorNeedles("gbdt eval").isEmpty)
        #expect(SearchMatch.locatorNeedles("https://example.com/report.html").contains("https://example.com/report.html"))
        #expect(SearchMatch.locatorNeedles("~/notes/plan.md").contains((("~/notes/plan.md") as NSString).expandingTildeInPath))
        let url = try transcript()
        let link = "https://example.com/artifacts/raw?key=by/someone/card-tags-proposal.html"
        let pad = Int(TranscriptIndex.chunkBytes) - 20   // the link starts 20 bytes before the first chunk ends
        try (String(repeating: "x", count: pad) + link + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(TranscriptIndex.rawContains(url, [link]) == link)
        #expect(TranscriptIndex.rawContains(url, ["https://example.com/other"]) == nil)
    }

    @Test func skipsHarnessTextAndToolOutput() throws {
        let url = try transcript()
        let toolResult = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"secret output\"}]}}\n"
        try (line("user", "<command-name>/compact</command-name>") + toolResult + line("user", "real prompt"))
            .write(to: url, atomically: true, encoding: .utf8)
        let entries = TranscriptIndex().entries(sessionId: session, cwd: cwd, format: ClaudeTranscript(projectsDir: projects))
        #expect(entries.map(\.text) == ["real prompt"])
    }

    @Test func forgetsSessionsNoLongerSearched() throws {
        let url = try transcript()
        try line("user", "hello").write(to: url, atomically: true, encoding: .utf8)
        let index = TranscriptIndex(); let format = ClaudeTranscript(projectsDir: projects)
        _ = index.entries(sessionId: session, cwd: cwd, format: format)
        index.retainOnly(sessionIds: [])
        // Re-reading from scratch still yields each message exactly once.
        #expect(index.entries(sessionId: session, cwd: cwd, format: format).count == 1)
    }
}
