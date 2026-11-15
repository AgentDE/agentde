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
                // An added agent's tools send keys or a command; code actions are for the built-in agents.
                agent.tools = agent.tools?.filter { !$0.id.isEmpty && ($0.keys?.isEmpty == false || $0.command?.isEmpty == false) }
                return agent
            }
    }

    static func definition(_ id: String?) -> AgentDefinition? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
