import AgentDEKit
import Foundation
import Testing
@testable import AgentDE

@Suite("Agent tools")
struct AgentToolTests {
    /// A plugin's agent with tools loads; one without stays loadable.
    @Test func pluginAgentsDecodeTools() throws {
        let json = """
        [{ "id": "hello.gemini", "name": "Gemini", "command": "gemini", "prompt": ">",
           "tools": [{ "id": "compact", "label": "Compact", "command": "/compress" },
                     { "id": "rewind", "label": "Rewind", "keys": "\\u001b\\u001b" }] },
         { "id": "plain", "name": "Plain", "command": "plain" }]
        """
        let agents = try JSONDecoder().decode([AgentDefinition].self, from: Data(json.utf8))
        #expect(agents[0].tools?.map(\.id) == ["compact", "rewind"])
        #expect(agents[0].tools?[1].keys == "\u{1B}\u{1B}")
        #expect(agents[0].prompt == ">")
        #expect(agents[1].tools == nil)
    }

    /// The draft guard reads any agent's prompt: Codex's `›`, not Claude's `❯`.
    @Test func draftUnderAnotherPrompt() {
        func row(_ text: String) -> [AgentInput.Cell] { text.map { AgentInput.Cell(character: $0, dim: false) } }
        let rows = [row("› fix the build"), row("  ⏎ send")]
        #expect(AgentInput.hasDraft(rows: rows, prompt: "›") == true)
        #expect(AgentInput.hasDraft(rows: rows) == nil)   // no `❯` line
        #expect(AgentInput.hasDraft(rows: [row("›  ")], prompt: "›") == false)
    }

    /// Built-ins use the same definitions: rewind and compact for both, the app's own actions only for Claude.
    @Test func builtInTools() {
        #expect(AgentCatalog.claude.tools?.map(\.id) == ["rewind", "compact", "fork", "restart"])
        #expect(AgentCatalog.codex.tools?.map(\.id) == ["rewind", "compact"])
        #expect(AgentCatalog.codex.tools?.allSatisfy { $0.keys != nil || $0.command != nil } == true)
    }
}
