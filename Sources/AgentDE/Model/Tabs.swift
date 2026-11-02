import Foundation

struct TabModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: TabKind
    var cwd: String
    var customTitle: String?
    var claudeSessionId: String?
    /// Codex tabs: the Codex thread to resume (`codex resume <id>`).
    var codexSessionId: String?
    var command: String?
    var browserURL: String?
    var showBrowser: Bool?
    /// Background Claude session (job id) this tab attaches to, e.g. one created by `/fork`.
    var attachJobId: String?
    /// Start by forking `claudeSessionId` (`--fork-session`) instead of resuming it. Cleared once the fork has its own id.
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
    var panelWidth: Double?
    var panelHidden: Bool?
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
    /// Shell commands run in each new tab of this group before its agent starts. Nil uses the app-wide default.
    var startupCommand: String?
    /// Whether the sidebar folds away this group's recent-session list.
    var hideRecent: Bool?
    /// Whether the sidebar hides this group's tabs. Sticky: independent of which group is selected.
    var collapsed: Bool?
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
}

struct RateLimits: Equatable {
    var fiveHour: Double?
    var sevenDay: Double?
}
