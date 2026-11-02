import AppKit
import Observation

/// All of AgentDE's state, and every change to it. Views read it; terminals, the agent monitor and the
/// widgets feed it. Main thread only. Saved state is `groups`, `selectedGroupID` and `settings`; the rest is live.
@Observable
final class Store {
    var groups: [GroupModel] = []
    var selectedGroupID: UUID?
    var settings = AgentDESettings() { didSet { if settings != oldValue { settingsChanged(from: oldValue) } } }
    var runtime: [UUID: TabRuntime] = [:]
    var rateLimits = RateLimits()
    /// Claude sessions active in the last `recentSessionDays`, newest first (filled by AgentMonitor).
    var recentSessions: [RecentSession] = []
    /// Session ids currently running anywhere on this Mac, from Claude's registry.
    var liveSessionIds: Set<String> = []
    /// Background sessions running now: session id → job id (what `claude attach` takes).
    var liveBackgroundJobs: [String: String] = [:]
    /// Open pull requests by folder and branch (`PullRequestMonitor.key`); nil means checked, none open.
    var pullRequests: [String: PullRequestStatus?] = [:]

    var paletteOpen = false
    var searchOpen = false
    /// The version installed on disk, when it's newer than the one running ("0.2.0 (41)").
    var updateInstalled: String?
    var sidebarVisible = true
    var renamingTabID: UUID?
    var renamingGroupID: UUID?
    /// The tab whose viewer shows its find bar. `viewerFindFocus` bumps on each ⌘F (to focus the field again),
    /// `viewerFindStep` on each ⌘G or ⌘⇧G (`viewerFindBackwards`).
    var viewerFindTab: UUID?
    var viewerFindFocus = 0
    var viewerFindStep = 0
    var viewerFindBackwards = false

    /// The native extensions loaded (`AgentDEMain.run`), in order, then JSON plugins.
    @ObservationIgnored let extensions: [AgentDEExtension] = AgentDEMain.extensions + [JSONPlugins()]
    @ObservationIgnored let terminals = TerminalRegistry()
    @ObservationIgnored var notifier: Notifier?
    @ObservationIgnored let search = SessionSearch()
    @ObservationIgnored lazy var pullRequestMonitor = PullRequestMonitor(store: self)
    /// Tabs that just ran `claude --bg` and haven't reported their job id yet, so `/fork` detection ignores their session.
    @ObservationIgnored var pendingBackgroundLaunches: [UUID: Date] = [:]
    /// When each tab last had focus; used to work out which tab a `/fork` came from.
    @ObservationIgnored var lastFocusedAt: [UUID: Date] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// `AGENTDE_STATE` points a test instance at its own state file, leaving yours alone.
    @ObservationIgnored private let stateURL = ProcessInfo.processInfo.environment["AGENTDE_STATE"]
        .map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: AppBrand.configDirectory).appendingPathComponent("state.json")

    init() {
        terminals.store = self
        terminals.viewers.onEscape = { [weak self] id in self?.closeViewer(id) }
        search.store = self
        load()
        attachToLiveBackgroundJobs(Store.liveBackgroundJobs(
            in: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")))
        if groups.isEmpty {
            let dir = NSHomeDirectory() + "/Documents"
            let group = GroupModel(name: "home", colorIndex: 0, dir: dir,
                                   tabs: [TabModel(kind: .shell, cwd: dir)])
            groups = [group]
            groups[0].selectedTabID = group.tabs.first?.id
            selectedGroupID = group.id
        }
        // Before any view exists: views call extensions' hooks from their first frame.
        startExtensions()
    }

    // MARK: Lookup

    var selectedGroup: GroupModel? { groups.first { $0.id == selectedGroupID } }
    var selectedGroupIndex: Int? { groups.firstIndex { $0.id == selectedGroupID } }

    /// The tab that keystrokes go to: the selected tab of the selected group.
    var activeTab: TabModel? {
        guard let group = selectedGroup else { return nil }
        return group.tabs.first { $0.id == group.selectedTabID } ?? group.tabs.first
    }

    func locate(_ tabID: UUID) -> (group: Int, tab: Int)? {
        for (g, group) in groups.enumerated() {
            if let t = group.tabs.firstIndex(where: { $0.id == tabID }) { return (g, t) }
        }
        return nil
    }

    func tab(_ id: UUID) -> TabModel? {
        locate(id).map { groups[$0.group].tabs[$0.tab] }
    }

    func title(for tab: TabModel) -> String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        let rt = runtime[tab.id]
        if let name = rt?.agentName, !name.isEmpty { return name }
        // A sleeping tab that will resume a session: the name it had last time, else the name Claude gave the
        // session (from the recent-sessions scan).
        if rt?.agentPresent != true, tab.claudeSessionId != nil || tab.attachJobId != nil || tab.codexSessionId != nil {
            if let last = tab.lastAgentName, !last.isEmpty { return last }
            if let session = tab.claudeSessionId,
               let named = recentSessions.first(where: { $0.sessionId == session })?.name { return named }
        }
        if tab.kind == .command { return "diff" }
        if tab.kind == .files { return (tab.cwd as NSString).lastPathComponent }
        if let title = rt?.terminalTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty, tab.kind == .shell {
            return title
        }
        if tab.kind == .shell { return (tab.cwd as NSString).lastPathComponent }
        return tab.kind.label.lowercased()
    }

    func state(_ tabID: UUID) -> AgentState { runtime[tabID]?.state ?? .none }

    func isVisible(_ tabID: UUID) -> Bool {
        guard let group = selectedGroup else { return false }
        return group.selectedTabID == tabID
    }

    func groupColor(_ group: GroupModel) -> NSColor {
        let hexes = GroupPalette.hexes(settings.palette)
        return NSColor(hex: hexes[((group.colorIndex % hexes.count) + hexes.count) % hexes.count])
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func save() {
        var snapshot = groups
        for g in snapshot.indices {
            snapshot[g].tabs.removeAll { $0.transient == true }
            snapshot[g].splitPanes = nil
        }
        let state = SavedState(groups: snapshot, selectedGroupID: selectedGroupID, settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Loads saved state group by group and tab by tab, so one unreadable entry (say, from a newer version)
    /// drops only itself. If anything is dropped, or the file can't be read at all, the original is kept as
    /// `state.json.unreadable-<time>` before AgentDE ever writes over it.
    private func load() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            backUpUnreadableState("not valid JSON")
            return
        }
        let decoder = JSONDecoder()
        var dropped = 0
        for case var rawGroup as [String: Any] in object["groups"] as? [Any] ?? [] {
            let rawTabs = rawGroup["tabs"] as? [Any] ?? []
            rawGroup["tabs"] = []
            guard let groupData = try? JSONSerialization.data(withJSONObject: rawGroup),
                  var group = try? decoder.decode(GroupModel.self, from: groupData) else { dropped += 1; continue }
            group.tabs = rawTabs.compactMap { raw in
                guard let tabData = try? JSONSerialization.data(withJSONObject: raw),
                      var tab = try? decoder.decode(TabModel.self, from: tabData) else { dropped += 1; return nil }
                tab.adoptLegacyWorkstream()
                return tab
            }
            groups.append(group)
        }
        if let selected = object["selectedGroupID"] as? String, let id = UUID(uuidString: selected),
           groups.contains(where: { $0.id == id }) {
            selectedGroupID = id
        } else {
            selectedGroupID = groups.first?.id
        }
        if let raw = object["settings"], let settingsData = try? JSONSerialization.data(withJSONObject: raw) {
            settings = AgentDESettings.decodeLenient(from: settingsData)
        }
        if dropped > 0 { backUpUnreadableState("\(dropped) group(s) or tab(s) couldn't be read") }
    }

    private func backUpUnreadableState(_ reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = stateURL.deletingLastPathComponent().appendingPathComponent("state.json.unreadable-\(stamp)")
        try? FileManager.default.copyItem(at: stateURL, to: backup)
        DebugLog.log("saved state: \(reason); kept the original as \(backup.lastPathComponent)", "state")
    }

    private func settingsChanged(from old: AgentDESettings) {
        if old.fontName != settings.fontName || old.fontSize != settings.fontSize
            || old.theme != settings.theme || old.appearance != settings.appearance
            || old.metalRenderer != settings.metalRenderer {
            terminals.applyAppearance()
        }
        if old.appIcon != settings.appIcon { AppIcons.apply(settings.appIcon) }
        scheduleSave()
    }

    // MARK: Helpers

    func focusActiveTerminal() {
        guard let id = activeTab?.id else { return }
        DispatchQueue.main.async { [weak self] in self?.terminals.focus(id) }
    }

    func confirm(_ message: String, detail: String, button: String = "Close") -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
