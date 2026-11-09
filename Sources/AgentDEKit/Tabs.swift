import Foundation

public enum TabKind: String, Codable, CaseIterable {
    case claude, codex, shell, command, files
    /// Another terminal agent, from an extension or JSON plugin (`AgentDefinition`, named by `TabModel.agentID`).
    case agent

    public var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: "Shell"
        case .command: "Command"
        case .files: "Files"
        case .agent: "Agent"
        }
    }

    public var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .shell: "terminal"
        case .command: "doc.text.magnifyingglass"
        case .files: "folder"
        case .agent: "cpu"
        }
    }
}

/// A terminal agent beyond Claude and Codex (Gemini CLI, OpenCode, Aider…), added by an extension's `agents` or a
/// JSON plugin's `"agents"`. Its tabs run `command` in the tab's folder; its status comes from its own hooks
/// (`AGENTDE_STATUS_FILE`, see docs/GUIDE.md).
public struct AgentDefinition: Codable, Equatable {
    /// Stable: tabs keep it to find the agent again after a relaunch.
    public var id: String
    public var name: String
    /// What the tab runs, through the login shell (`gemini`, `opencode`, `aider --model sonnet`).
    public var command: String
    public init(id: String, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

/// What a tab's agent is doing, as far as AgentDE can tell.
public enum AgentState: Equatable {
    case none, working, needsYou, doneUnseen
}
