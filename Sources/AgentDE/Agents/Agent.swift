import AgentDEKit
import Foundation

/// What an agent does in a tab. Claude and Codex are built in (`ClaudeAgent`, `CodexAgent`), written natively, so
/// they can reach the store directly; agents from extensions and JSON plugins run through `PluginAgent`. The core
/// asks a tab's agent (`Agents.of`) rather than checking which agent it is.
protocol Agent {
    /// Name, icon, input prompt, stash keys, and the buttons a plugin can declare.
    var definition: AgentDefinition { get }
    /// What the tab runs after its startup command, or nil for nothing.
    func command(for tab: TabModel) -> String?
    /// The chat's corner buttons, which the tab's menu lists too.
    var actions: [AgentAction] { get }
    /// Whether a new session takes the name you give the tab (Claude's `--name`).
    var namesSessions: Bool { get }
    /// A scanner for the sessions you started and named, for the Recent and Older lists; nil when none.
    func sessionScanner() -> SessionScanner?
    /// Where and how its conversations are kept, for search and partial-path links; nil when AgentDE can't read them.
    var transcript: TranscriptFormat? { get }
    /// Its last reply in a session, for the Done notification; nil when it can't say.
    func lastReply(session: String, cwd: String) -> String?
    /// A background job already running `session`, which a resuming tab attaches to instead of starting a
    /// second copy (Claude's background sessions); nil when there's none.
    func liveBackgroundJob(session: String, store: Store) -> String?
}

/// Finds an agent's named sessions on disk, newest first; caches what it read between scans.
protocol SessionScanner: AnyObject {
    func scan(days: Double) -> [RecentSession]
}

extension Agent {
    var id: String { definition.id }
    var name: String { definition.name }
    var symbol: String { definition.symbol ?? TabKind.agent.symbol }
    var namesSessions: Bool { false }
    func sessionScanner() -> SessionScanner? { nil }
    var transcript: TranscriptFormat? { nil }
    func lastReply(session: String, cwd: String) -> String? { nil }
    func liveBackgroundJob(session: String, store: Store) -> String? { nil }
}

/// One of an agent's buttons: keys or a command typed into its input (all a JSON plugin can declare), or code
/// (built-in agents: Claude's Fork and Restart).
struct AgentAction: Identifiable {
    enum Run {
        case keys(String)
        case command(String)
        case code(enabled: (Store, TabModel) -> Bool, run: (Store, UUID) -> Void)
    }

    let id: String
    let label: String
    let symbol: String
    let help: String
    let run: Run

    init(id: String, label: String, symbol: String, help: String, run: Run) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.help = help
        self.run = run
    }

    /// A declared tool; nil when it has neither keys nor a command.
    init?(_ tool: AgentTool) {
        let run: Run
        if let keys = tool.keys, !keys.isEmpty {
            run = .keys(keys)
        } else if let command = tool.command, !command.isEmpty {
            run = .command(command)
        } else {
            return nil
        }
        self.init(id: tool.id, label: tool.label, symbol: tool.symbol ?? "command",
                  help: tool.help ?? tool.command ?? tool.label, run: run)
    }
}

/// Finding a tab's agent.
enum Agents {
    static func of(_ tab: TabModel) -> (any Agent)? {
        switch tab.kind {
        case .agent: tab.agentID.flatMap(byID)
        // A shell tab that was running Claude (it registered there) picks that session back up.
        case .shell: tab.agentSession != nil || tab.attachJobId != nil ? ClaudeAgent.shared : nil
        case .command, .files: nil
        }
    }

    /// The built-in agents, then those extensions and JSON plugins add.
    static var all: [any Agent] { [ClaudeAgent.shared, CodexAgent.shared] + AgentCatalog.all.map(PluginAgent.init) }

    static func byID(_ id: String) -> (any Agent)? {
        switch id {
        case ClaudeAgent.id: ClaudeAgent.shared
        case CodexAgent.id: CodexAgent.shared
        default: AgentCatalog.definition(id).map(PluginAgent.init)
        }
    }
}

/// An agent from an extension or a JSON plugin: its command, and the buttons it declares.
struct PluginAgent: Agent {
    let definition: AgentDefinition
    func command(for tab: TabModel) -> String? { definition.command }
    var actions: [AgentAction] { (definition.tools ?? []).compactMap(AgentAction.init) }
}
