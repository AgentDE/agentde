import Foundation

struct TabModel: Identifiable, Codable, Equatable {
    /// A tab running agent `id` ("claude", "codex", an added agent's).
    static func agent(_ id: String, cwd: String, session: String? = nil) -> TabModel {
        var tab = TabModel(kind: .agent, cwd: cwd)
        tab.agentID = id
        tab.agentSession = session
        return tab
    }

    /// Whether it's a tab of agent `id`.
    func runs(_ id: String) -> Bool { kind == .agent && agentID == id }

    var id = UUID()
    var kind: TabKind
    var cwd: String
    var customTitle: String?
    /// The agent's session to resume: Claude's session id, Codex's thread id (`Agent.command`). A shell tab can
    /// hold Claude's too, when Claude was running in it.
    var agentSession: String?
    var command: String?
    /// A name for the agent session this tab starts (Claude's `--name`), used only when it starts a new one.
    var sessionName: String?
    /// When its agent last worked or waited on you, or you last switched to it (the sidebar's active-today filter).
    var lastActiveAt: Date?
    /// Agent tabs: which agent they run ("claude", "codex", or an added agent's id; `Agents.of`).
    var agentID: String?
    /// Sent to the background: out of the tab strip and splits, still running in its holder. The sidebar lists
    /// it under the group's Background; choosing it brings it back.
    var background: Bool?
    /// Background Claude session (job id) this tab attaches to, e.g. one created by `/fork`.
    var attachJobId: String?
    /// Start by forking `agentSession` (Claude's `--fork-session`) instead of resuming it. Cleared once the fork has its own id.
    var forkOnStart: Bool?
    /// Transient tabs (diff views and similar) close when their process exits and are not saved.
    var transient: Bool?
    /// The Claude session's name when last seen, shown while the tab sleeps (before it's opened after a relaunch).
    var lastAgentName: String?
    /// File Explorer tabs: the selected file, restored on relaunch.
    var explorerSelection: String?
    /// Saved by versions with a shell drawer: the drawer's shell. At launch a drawer whose shell is still
    /// running becomes its own shell tab (`Store.adoptLegacyDrawers`); then both are cleared.
    var showShell: Bool?
    var companionID: UUID?
    /// Saved by versions before extensions: the tab's workstream. Moved into `extensionData` at load.
    var workstreamID: String?
    /// What the viewer above the chat shows: a file path or a localhost URL.
    var viewerItem: String?
    var viewerHeight: Double?
    /// The viewer fills the tab, hiding the chat.
    var viewerExpanded: Bool?
    /// The viewer shows a Markdown file's text rather than rendering it.
    var viewerRaw: Bool?
    /// Files and pages the viewer has shown, newest first (`ViewerHistory`).
    var viewerHistory: [String]?
    var panelWidth: Double?
    var panelHidden: Bool?
    /// Which side panel tab shows (`SidePanelTab.id`); the first when unset or gone.
    var panelTab: String?
    /// Saved by versions before extensions: the workstream panel's open sections. Moved into `extensionData` at load.
    var panelSections: [String: Bool]?
    /// Values native extensions keep with the tab, keyed "<extension id>.<key>" (`AgentDEHost.value`).
    var extensionData: [String: String]?

    /// Moves what versions before extensions saved into the Workstreams extension's values.
    mutating func adoptLegacyWorkstream() {
        var data = extensionData ?? [:]
        if let id = workstreamID, data["workstreams.id"] == nil { data["workstreams.id"] = id }
        if let sections = panelSections, data["workstreams.sections"] == nil,
           let json = try? JSONEncoder().encode(sections) { data["workstreams.sections"] = String(decoding: json, as: UTF8.self) }
        workstreamID = nil
        panelSections = nil
        extensionData = data.isEmpty ? nil : data
    }
}

struct GroupModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var dir: String
    var tabs: [TabModel] = []
    var selectedTabID: UUID?
    /// Saved by versions with split view. Ignored, and dropped on the next save.
    var splitPanes: [UUID]?
    /// Tabs shown side by side or stacked (`PaneLayout`); nil shows the selected tab alone.
    var layout: PaneLayout?
    /// Shell commands run in each new tab of this group before its agent starts. Nil uses the app-wide default.
    var startupCommand: String?
    /// Whether the sidebar folds away this group's recent-session list.
    var hideRecent: Bool?
    /// Past sessions pinned to the top of the group's session list, newest pin first. Saved whole, so a
    /// pinned session stays listed after it ages out of Recent.
    var pinnedSessions: [RecentSession]?
    /// Whether the sidebar hides this group's tabs. Sticky: independent of which group is selected.
    var collapsed: Bool?

    /// The tabs in the tab strip: all but those sent to the background.
    var shownTabs: [TabModel] { tabs.filter { $0.background != true } }
}

/// Live, unsaved state for a tab.
struct TabRuntime {
    var state: AgentState = .none
    var agentName: String?
    var terminalTitle: String?
    var busySince: Date?
    var sparkleToken = 0
    var sparkleAt: Date?
    /// What a waiting agent needs, from Claude's registry (`waitingFor`), e.g. a permission prompt.
    var waitingFor: String?
    /// Whether a Claude session is running for this tab, tracked apart from its (optional) name.
    var agentPresent = false
    /// The tab's process has been launched in this run (tabs start lazily, when first shown).
    var started = false
    /// Consecutive polls without the tab's session, so one failed read doesn't count as Claude exiting.
    var missedPolls = 0
    /// The tab's Claude process (for a background tab, its job's process) and the Claude Code version it runs.
    var agentPid: pid_t?
    var claudeVersion: String?
}

