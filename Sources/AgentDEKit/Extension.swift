import AppKit
import SwiftUI

/// A native extension: a feature built against this API (Workstreams, Widgets, Linear…) that the app loads at
/// launch. Every hook has a default that does nothing, so an extension implements only what it adds. The
/// app calls hooks on the main thread.
public protocol AgentDEExtension: AnyObject {
    /// A stable id, used for its saved settings and per-tab data ("workstreams").
    var id: String { get }
    /// Shown in Settings.
    var name: String { get }

    /// Called once at launch, after saved state is loaded.
    func start(host: AgentDEHost)
    /// Called at quit; save anything that's behind.
    func stop()

    // MARK: Tabs and agents

    /// Environment variables for a tab's shell, set when it starts.
    func launchEnvironment(for tab: TabInfo) -> [String: String]
    /// The app re-read which agent session each tab runs (a tab started Claude, `/clear`, a resume…).
    func agentSessionsChanged()
    /// The agent sessions running anywhere on this Mac, after each registry poll.
    func liveSessionsChanged(_ live: Set<String>)
    /// A tab's agent went idle (finished a turn or is waiting).
    func agentWentIdle(_ tab: TabInfo)
    /// A tab is closing. With `keepAgent` its background agent keeps running.
    func tabClosing(_ tab: TabInfo, keepAgent: Bool)
    /// The app opened a tab for a background session (a `/fork`, or `claude --bg`); `forkParent` is the
    /// session it was forked from, when Claude recorded one.
    func backgroundSessionOpened(_ tab: TabInfo, session: String?, forkParent: String?)
    /// Whether a tab wants the user's attention without its agent being stopped (an open question, say):
    /// the tab gets a soft ring.
    func wantsAttention(_ tab: TabInfo) -> Bool

    // MARK: UI slots

    /// Tabs this extension adds to the side panel beside a terminal tab (Workstream, say). They come before
    /// the core's Files and Changes, in extension order.
    func sidePanelTabs(for tab: TabInfo) -> [SidePanelTab]
    /// The area at the bottom of the sidebar. The first extension that returns one owns it.
    func sidebarFooter() -> AnyView?
    /// Something drawn over the whole window, passing clicks through (an animation, say).
    func windowOverlay() -> AnyView?
    /// Controls in the viewer's header for the item it shows (a file path or a link).
    func viewerAccessory(for tab: TabInfo, item: String) -> AnyView?
    /// A better title for a link shown in the viewer than the link itself.
    func title(forLink link: String, in tab: TabInfo) -> String?
    /// Items for a group's New menu.
    func newMenuItems(for group: GroupInfo) -> [ExtensionAction]
    /// The extension's section in Settings.
    func settingsView() -> AnyView?

    // MARK: Contributions

    /// Links that open in the viewer rather than the browser (artifact pages, say).
    var linkRules: [LinkRule] { get }
    /// Themes added to Settings → Look.
    var themes: [ThemeDefinition] { get }
    /// Group color palettes added to Settings → Look.
    var palettes: [PaletteDefinition] { get }
    /// Trackers whose tickets this extension can look up.
    var ticketProviders: [TicketProvider] { get }
    /// Terminal agents added to the New menus beside Claude and Codex.
    var agents: [AgentDefinition] { get }
}

public extension AgentDEExtension {
    func start(host: AgentDEHost) {}
    func stop() {}
    func launchEnvironment(for tab: TabInfo) -> [String: String] { [:] }
    func agentSessionsChanged() {}
    func liveSessionsChanged(_ live: Set<String>) {}
    func agentWentIdle(_ tab: TabInfo) {}
    func tabClosing(_ tab: TabInfo, keepAgent: Bool) {}
    func backgroundSessionOpened(_ tab: TabInfo, session: String?, forkParent: String?) {}
    func wantsAttention(_ tab: TabInfo) -> Bool { false }
    func sidePanelTabs(for tab: TabInfo) -> [SidePanelTab] { [] }
    func sidebarFooter() -> AnyView? { nil }
    func windowOverlay() -> AnyView? { nil }
    func viewerAccessory(for tab: TabInfo, item: String) -> AnyView? { nil }
    func title(forLink link: String, in tab: TabInfo) -> String? { nil }
    func newMenuItems(for group: GroupInfo) -> [ExtensionAction] { [] }
    func settingsView() -> AnyView? { nil }
    var linkRules: [LinkRule] { [] }
    var themes: [ThemeDefinition] { [] }
    var palettes: [PaletteDefinition] { [] }
    var ticketProviders: [TicketProvider] { [] }
    var agents: [AgentDefinition] { [] }
}

/// What the app offers extensions. It's the app's own observable state, so a view that reads it updates when
/// it changes. Main thread only.
public protocol AgentDEHost: AnyObject {
    /// Every tab, group by group, in sidebar order.
    var allTabs: [TabInfo] { get }
    var allGroups: [GroupInfo] { get }
    func tabInfo(_ id: UUID) -> TabInfo?
    var activeTabID: UUID? { get }
    /// Agent sessions running anywhere on this Mac.
    var liveSessions: Set<String> { get }
    /// Claude's 5-hour and 7-day limits used, 0–100, when known.
    var rateLimitsUsed: (fiveHour: Double?, sevenDay: Double?) { get }
    /// Whether the user wants motion (Settings → Fun, and Reduce Motion).
    var animations: Bool { get }
    /// The extensions loaded, for working with each other (`extensions.compactMap { $0 as? SomeProtocol }`).
    var extensions: [AgentDEExtension] { get }

    func selectTab(_ id: UUID, focus: Bool)
    /// Types text into a tab's terminal, as if pasted ("\r" presses Return).
    func type(_ text: String, into tab: UUID)
    /// Shows a file path or link in a tab's viewer.
    func openInViewer(_ item: String, tab: UUID, select: Bool)
    /// Opens a new tab and returns its id.
    @discardableResult
    func openTab(kind: TabKind, in group: UUID, folder: String?, title: String?) -> UUID?

    /// Small per-tab values an extension keeps with the tab (saved with it). Keys are namespaced by the
    /// extension's id.
    func value(_ key: String, tab: UUID, for ext: AgentDEExtension) -> String?
    func setValue(_ value: String?, _ key: String, tab: UUID, for ext: AgentDEExtension)
    /// The extension's saved settings, as JSON it encodes itself; nil until it saves some.
    func settingsData(for ext: AgentDEExtension) -> Data?
    func setSettingsData(_ data: Data?, for ext: AgentDEExtension)

    /// A modal alert with one OK button.
    func showProblem(_ message: String, _ detail: String)
    /// The app's folder under `~/.config` (state, logs, extension files).
    var configDirectory: URL { get }
}

public extension AgentDEHost {
    /// An extension's saved settings, decoded, or `fallback`.
    func settings<T: Decodable>(_ type: T.Type, for ext: AgentDEExtension, fallback: T) -> T {
        settingsData(for: ext).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback
    }

    func saveSettings<T: Encodable>(_ value: T, for ext: AgentDEExtension) {
        setSettingsData(try? JSONEncoder().encode(value), for: ext)
    }
}

/// A tab as extensions see it.
public struct TabInfo: Identifiable, Equatable {
    public var id: UUID
    public var groupID: UUID
    public var kind: TabKind
    /// The tab's working folder.
    public var folder: String
    /// Its group's folder.
    public var groupFolder: String
    public var title: String
    /// The agent session it runs: Claude's session id, or Codex's thread id.
    public var agentSession: String?
    /// Whether an agent is running in it now (a shell tab can run Claude too).
    public var agentPresent: Bool
    public var state: AgentState
    /// What its viewer shows: a file path or a link.
    public var viewerItem: String?

    public init(id: UUID, groupID: UUID, kind: TabKind, folder: String, groupFolder: String, title: String,
                agentSession: String?, agentPresent: Bool, state: AgentState, viewerItem: String? = nil) {
        self.id = id
        self.groupID = groupID
        self.kind = kind
        self.folder = folder
        self.groupFolder = groupFolder
        self.title = title
        self.agentSession = agentSession
        self.agentPresent = agentPresent
        self.state = state
        self.viewerItem = viewerItem
    }

    /// Agent tabs, and other tabs while an agent runs in them.
    public var isAgent: Bool { kind == .claude || kind == .codex || kind == .agent || agentSession != nil || agentPresent }
}

public struct GroupInfo: Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var folder: String
    public init(id: UUID, name: String, folder: String) {
        self.id = id
        self.name = name
        self.folder = folder
    }
}

/// A menu item an extension adds.
/// One tab of the side panel: a short title and SF Symbol for its header, and what it shows.
public struct SidePanelTab: Identifiable {
    /// Stable across launches: the tab remembers which one was showing.
    public var id: String
    public var title: String
    public var symbol: String
    public var view: AnyView
    public init(id: String, title: String, symbol: String, view: AnyView) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.view = view
    }
}

public struct ExtensionAction {
    public var title: String
    public var symbol: String?
    public var action: () -> Void
    public init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }
}

/// Links that open in the viewer: a pattern that finds them in text (and in agents' transcripts), how to
/// name one, and what to load for it.
public struct LinkRule {
    /// A regular expression matching the whole link.
    public var pattern: String
    /// Text every such link contains ("example.com/pages/"), for skipping text quickly.
    public var marker: String
    /// One form per page (say, a raw link becomes its view page); nil when the match names nothing.
    public var canonical: (String) -> String?
    /// The address to load for a canonical link.
    public var openURL: (String) -> String
    /// A title from the link itself.
    public var title: (String) -> String?

    public init(pattern: String, marker: String, canonical: @escaping (String) -> String? = { $0 },
                openURL: @escaping (String) -> String = { $0 }, title: @escaping (String) -> String? = { _ in nil }) {
        self.pattern = pattern
        self.marker = marker
        self.canonical = canonical
        self.openURL = openURL
        self.title = title
    }
}

/// A theme for Settings → Look.
public struct ThemeDefinition {
    public var id: String
    public var name: String
    /// Ignores the light/dark setting.
    public var alwaysDark: Bool
    public var resolve: (_ dark: Bool) -> Theme
    /// The mascot shown in place of the app icon (empty tabs, the sidebar) while this theme is on.
    public var logo: ((_ size: CGFloat) -> NSImage)?
    public init(id: String, name: String, alwaysDark: Bool = false, logo: ((_ size: CGFloat) -> NSImage)? = nil,
                resolve: @escaping (_ dark: Bool) -> Theme) {
        self.id = id
        self.name = name
        self.alwaysDark = alwaysDark
        self.logo = logo
        self.resolve = resolve
    }
}

/// Group colors for Settings → Look: eight colors, as 0xRRGGBB.
public struct PaletteDefinition {
    public var id: String
    public var name: String
    public var colors: [UInt32]
    public init(id: String, name: String, colors: [UInt32]) {
        self.id = id
        self.name = name
        self.colors = colors
    }
}

/// A tracker's view of one ticket.
public struct TicketInfo: Equatable {
    public var identifier: String
    public var title: String
    public var url: String
    /// Its state's name ("In Progress") and kind ("started", "completed"…), when known.
    public var state: String?
    public var stateType: String?
    public var colorHex: UInt32?
    /// 1 urgent, 2 high, 3 medium, 4 low; 0 for none.
    public var priority: Int

    public init(identifier: String, title: String, url: String, state: String? = nil, stateType: String? = nil, colorHex: UInt32? = nil,
                priority: Int = 0) {
        self.identifier = identifier
        self.title = title
        self.url = url
        self.state = state
        self.stateType = stateType
        self.colorHex = colorHex
        self.priority = priority
    }
}

/// A tracker the app can look tickets up in (Linear, Jira…).
public protocol TicketProvider: AnyObject {
    /// "linear": matches `Ticket.tracker` for tickets linked from its links.
    var tracker: String { get }
    var name: String { get }
    /// Whether it's signed in and can look things up.
    var isReady: Bool { get }
    /// Whether this provider should look up a ticket linked by key alone ("ENG-123"), with no tracker known.
    func claims(identifier: String) -> Bool
    /// Looks tickets up; calls back on the main thread with the ones it found.
    func lookUp(_ identifiers: [String], completion: @escaping ([TicketInfo]) -> Void)
    /// The user's own open tickets, for picking one to link.
    func myTickets(completion: @escaping ([TicketInfo]) -> Void)
}
