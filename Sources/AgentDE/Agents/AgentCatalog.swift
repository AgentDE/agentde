import Foundation

/// The agents extensions and JSON plugins add (`AgentDefinition`), beside the built-in Claude and Codex.
enum AgentCatalog {
    /// Every added agent, first definition of an id winning.
    static var all: [AgentDefinition] {
        var seen = Set<String>()
        return AgentDEMain.extensions.flatMap(\.agents)
            .filter { !$0.id.isEmpty && !$0.command.isEmpty && seen.insert($0.id).inserted }
            .map { agent in
                var agent = agent
                // An added agent's tools send keys or a command; the app's own actions are for the built-ins.
                agent.tools = agent.tools?.filter { !$0.id.isEmpty && ($0.keys?.isEmpty == false || $0.command?.isEmpty == false) }
                return agent
            }
    }

    /// Claude Code, as the same kind of definition (its tabs are launched by the app, not by `command`).
    /// Fork and Restart, with no keys or command, are the app's own actions.
    static let claude = AgentDefinition(id: "claude", name: "Claude", command: "claude", tools: [
        .init(id: "rewind", label: "Rewind", symbol: "arrow.uturn.backward", keys: "\u{1B}\u{1B}", help: "Go back to an earlier message (⌥⌘Z)"),
        .init(id: "compact", label: "Compact", symbol: "rectangle.compress.vertical", command: "/compact", help: "Compact the conversation (/compact)"),
        .init(id: "fork", label: "Fork", symbol: "arrow.triangle.branch", help: "Fork into a new tab (⌥⌘F)"),
        .init(id: "restart", label: "Restart", symbol: "arrow.clockwise", help: "Restart Claude, keeping the session"),
    ], prompt: "❯")

    static let codex = AgentDefinition(id: "codex", name: "Codex", command: "codex", tools: [
        .init(id: "rewind", label: "Rewind", symbol: "arrow.uturn.backward", keys: "\u{1B}\u{1B}", help: "Edit an earlier message (⌥⌘Z)"),
        .init(id: "compact", label: "Compact", symbol: "rectangle.compress.vertical", command: "/compact", help: "Compact the conversation (/compact)"),
    ], prompt: "›")

    static func definition(_ id: String?) -> AgentDefinition? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
