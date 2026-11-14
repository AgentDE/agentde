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
    /// Buttons in the chat's top-right corner.
    public var tools: [AgentTool]?
    /// The character that starts the agent's input line (`❯` for Claude Code). With it, tools leave a draft
    /// you're typing alone instead of erasing it or appending to it.
    public var prompt: String?
    public init(id: String, name: String, command: String, tools: [AgentTool]? = nil, prompt: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.tools = tools
        self.prompt = prompt
    }
}

/// One of an agent's chat tools: keys sent to it (`keys`), or a command typed and sent (`command`). Tools run
/// only while the agent waits for you. The ids `rewind` and `compact` also run from the Session menu (⌥⌘Z) and
/// the palette.
public struct AgentTool: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// An SF Symbol name.
    public var symbol: String?
    /// Sent a character at a time, a moment apart (`"\u001b\u001b"` is Esc Esc).
    public var keys: String?
    /// Typed, then Enter (`/compact`).
    public var command: String?
    /// The tooltip.
    public var help: String?
    public init(id: String, label: String, symbol: String? = nil, keys: String? = nil, command: String? = nil, help: String? = nil) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.keys = keys
        self.command = command
        self.help = help
    }
}

/// What a tab's agent is doing, as far as AgentDE can tell.
public enum AgentState: Equatable {
    case none, working, needsYou, doneUnseen
}
