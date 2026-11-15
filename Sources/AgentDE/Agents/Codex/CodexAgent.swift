import AgentDEKit
import Foundation

/// OpenAI's Codex CLI. Tabs resume their thread (`codex resume <id>`); the id comes from its status hook.
struct CodexAgent: Agent {
    static let shared = CodexAgent()
    static let id = "codex"

    let definition = AgentDefinition(id: CodexAgent.id, name: "Codex", command: "codex", tools: [
        .init(id: "rewind", label: "Rewind", symbol: "arrow.uturn.backward", keys: "\u{1B}\u{1B}", help: "Edit an earlier message (⌥⌘Z)"),
        .init(id: "compact", label: "Compact", symbol: "rectangle.compress.vertical", command: "/compact", help: "Compact the conversation (/compact)"),
    ], prompt: "›", symbol: "chevron.left.forwardslash.chevron.right")

    func command(for tab: TabModel) -> String? {
        "codex" + (SafeID.session(tab.agentSession).map { " resume \($0)" } ?? "")
    }

    var actions: [AgentAction] { (definition.tools ?? []).compactMap(AgentAction.init) }
    func sessionScanner() -> SessionScanner? { CodexSessionScanner() }
    var transcript: TranscriptKind? { .codex }
}
