import Foundation

public enum TabKind: String, Codable, CaseIterable {
    case claude, codex, shell, command, files

    public var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: "Shell"
        case .command: "Command"
        case .files: "Files"
        }
    }

    public var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .shell: "terminal"
        case .command: "doc.text.magnifyingglass"
        case .files: "folder"
        }
    }
}

/// What a tab's agent is doing, as far as AgentDE can tell.
public enum AgentState: Equatable {
    case none, working, needsYou, doneUnseen
}
