import Foundation

/// The agents extensions and JSON plugins add (`AgentDefinition`), beside the built-in Claude and Codex.
enum AgentCatalog {
    /// Every added agent, first definition of an id winning.
    static var all: [AgentDefinition] {
        var seen = Set<String>()
        return AgentDEMain.extensions.flatMap(\.agents).filter { !$0.id.isEmpty && !$0.command.isEmpty && seen.insert($0.id).inserted }
    }

    static func definition(_ id: String?) -> AgentDefinition? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
