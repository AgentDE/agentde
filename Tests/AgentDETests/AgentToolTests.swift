import AgentDEKit
import Foundation
import Testing
@testable import AgentDE

@Suite("Agent tools")
struct AgentToolTests {
    /// A plugin's agent with tools loads; one without stays loadable.
    @Test func pluginAgentsDecodeTools() throws {
        let json = """
        [{ "id": "hello.gemini", "name": "Gemini", "command": "gemini", "prompt": ">", "stash": "\\u0013",
           "tools": [{ "id": "compact", "label": "Compact", "command": "/compress" },
                     { "id": "rewind", "label": "Rewind", "keys": "\\u001b\\u001b" }] },
         { "id": "plain", "name": "Plain", "command": "plain" }]
        """
        let agents = try JSONDecoder().decode([AgentDefinition].self, from: Data(json.utf8))
        #expect(agents[0].tools?.map(\.id) == ["compact", "rewind"])
        #expect(agents[0].tools?[1].keys == "\u{1B}\u{1B}")
        #expect(agents[0].prompt == ">" && agents[0].stash == "\u{13}")
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
        #expect(ClaudeAgent.shared.actions.map(\.id) == ["rewind", "compact", "fork", "restart"])
        #expect(CodexAgent.shared.actions.map(\.id) == ["rewind", "compact"])
        // A plugin's tool without keys or a command does nothing, so it isn't a button.
        let plugin = PluginAgent(definition: AgentDefinition(id: "p", name: "P", command: "p", tools: [
            AgentTool(id: "fork", label: "Fork"), AgentTool(id: "go", label: "Go", command: "/go")]))
        #expect(plugin.actions.map(\.id) == ["go"])
        // Claude stashes a draft for a command (Ctrl+S, checked against Claude Code 2.1.325); Codex waits for an empty input.
        #expect(ClaudeAgent.shared.definition.stash == "\u{13}" && CodexAgent.shared.definition.stash == nil)
        // What each agent brings beyond buttons: Claude and Codex read their own transcripts and Recent lists,
        // only Claude names sessions; a plugin agent has none of these.
        #expect(ClaudeAgent.shared.transcript == .claude && CodexAgent.shared.transcript == .codex && plugin.transcript == nil)
        #expect(ClaudeAgent.shared.sessionScanner() != nil && CodexAgent.shared.sessionScanner() != nil && plugin.sessionScanner() == nil)
        #expect(ClaudeAgent.shared.namesSessions && !CodexAgent.shared.namesSessions && !plugin.namesSessions)
        #expect(Agents.byID("claude")?.id == "claude" && Agents.byID("codex")?.id == "codex" && Agents.byID("nope") == nil)
        #expect(Agents.of(TabModel.agent("codex", cwd: "/tmp"))?.id == "codex")
        #expect(Agents.of(TabModel(kind: .shell, cwd: "/tmp")) == nil)
    }

    /// Claude says "busy" while it only waits on workflows: a quiet screen without a spinner means idle; a recent
    /// redraw, or a spinner on screen, means a turn is running.
    @Test func quietClaudeWithoutSpinnerIsIdle() {
        let now = Date()
        let waiting = ["* Waiting for 3 dynamic workflows to finish", "* Baked for 59s · done 11:12 AM", "❯ "]
        let running = ["✽ Zesting… (4m 43s · ↓ 15.4k tokens)", "❯ "]
        #expect(ClaudeActivity.looksIdle(screen: { waiting }, lastOutput: now.addingTimeInterval(-30), now: now))
        #expect(!ClaudeActivity.looksIdle(screen: { waiting }, lastOutput: now.addingTimeInterval(-1), now: now))
        #expect(!ClaudeActivity.looksIdle(screen: { running }, lastOutput: now.addingTimeInterval(-30), now: now))
        #expect(!ClaudeActivity.looksIdle(screen: { waiting }, lastOutput: nil, now: now))   // nothing seen yet
        #expect(ClaudeActivity.isSpinner("✻ Cogitating… (12s · ↓ 1.2k tokens · esc to interrupt)"))
        #expect(ClaudeActivity.isSpinner("· Pondering… (1h 2m 3s)"))
        #expect(!ClaudeActivity.isSpinner("* Churned for 17m 48s · done 11:27 AM"))
    }
}
