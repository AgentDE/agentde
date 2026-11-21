import AppKit
import Observation

/// All of AgentDE's state, and every change to it. Views read it; terminals, the agent monitor and the
/// widgets feed it. Main thread only. Saved state is `groups`, `selectedGroupID` and `settings`; the rest is live.
@Observable
final class Store {
    var groups: [GroupModel] = []
    var selectedGroupID: UUID?
    /// Background jobs a `claude stop` is ending right now, and ones whose stop failed.
    var stoppingJobs = Set<String>()
    var failedStops = Set<String>()
    /// Recently closed tabs, for Reopen Closed Tab.
    var closedTabs: [ClosedTab] = []
    /// Why the last save failed, while it's failing (the status bar shows it with a Retry).
    var saveError: String?
    var settings = AgentDESettings() { didSet { if settings != oldValue { settingsChanged(from: oldValue) } } }
    var runtime: [UUID: TabRuntime] = [:]
    /// Claude sessions active in the last `recentSessionDays`, newest first (filled by AgentMonitor).
    var recentSessions: [RecentSession] = []
    /// How often you've opened each file or page in a viewer (`openInViewer`), for the Most opened sorts. Saved;
    /// at most `ViewerOpens.limit` items, the least opened dropped first.
    @ObservationIgnored var viewerOpenCounts: [String: Int] = [:]
    @ObservationIgnored var viewerOpenedAt: [String: Date] = [:]
    /// Sessions older than that, scanned when a group's Older list opens; nil until the first scan is in.
    var olderSessions: [RecentSession]?
    /// Groups whose Older list is open (not saved).
    var olderShown: Set<UUID> = []
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
    /// The Claude Code version installed on disk (`ClaudeVersion.installed`), refreshed every few minutes.
    var installedClaudeVersion: String?
    /// Progress, then the summary, of Restart Idle Claude Tabs, shown in the status bar for a while.
    var claudeRestartNote: String?
    /// A short note in the status bar about something in progress or just finished ("Making worktree fix-login…").
    var activityNote: String?
    /// Tabs whose Claude is restarting now.
    var restartingClaude: Set<UUID> = []
    /// Tabs reconnecting to their holder (after a relaunch): covered while the holder replays their history
    /// and the agent redraws, until shortly after the replay ends (`TerminalSession.handle(.replayEnd)`).
    var reconnectingTabs: Set<UUID> = []
    /// Tabs whose restart has relaunched Claude, waiting for it to come back (its old pid): the tab stays covered
    /// until a new Claude registers, or 25 seconds pass.
    var claudeComingBack: [UUID: pid_t] = [:]
    /// Tabs resuming a session, by the session's name: covered until the agent has drawn the conversation
    /// (`ResumeCover`).
    var resumingTabs: [UUID: String] = [:]
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
    /// The sidebar's search box: filters groups, tabs and sessions by name as you type, and finds the query in
    /// conversations (`sidebarSearch`, which includes Recent).
    var sidebarQuery = "" { didSet { if sidebarQuery != oldValue { sidebarSearch.query = sidebarQuery.count >= 3 ? sidebarQuery : "" } } }
    @ObservationIgnored let sidebarSearch = SessionSearch()
    /// Bumped by ⌘K to put the cursor in the sidebar's search box.
    var sidebarSearchFocus = 0
    @ObservationIgnored lazy var pullRequestMonitor = PullRequestMonitor(store: self)
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
        terminals.viewers.onOpen = { [weak self] id, item in self?.followViewerLink(item, tab: id) }
        search.store = self
        sidebarSearch.store = self
        sidebarSearch.includeRecent = true
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
        // Older sessions, so groups with only old ones still show an Older fold. Delayed past launch, when
        // tabs reattach and replay their history.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.settings.showRecentSessions else { return }
            self.loadOlderSessions()
        }
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
        // A sleeping tab that will resume a session, or a running one Claude hasn't named: the name it had last
        // time, else the session's title (from the recent-sessions scan).
        if tab.agentSession != nil || tab.attachJobId != nil {
            if let last = tab.lastAgentName, !last.isEmpty { return last }
            if let session = tab.agentSession,
               let named = recentSessions.first(where: { $0.sessionId == session })?.name { return named }
        }
        if tab.kind == .command { return "diff" }
        if tab.kind == .files { return (tab.cwd as NSString).lastPathComponent }
        if let title = rt?.terminalTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty, tab.kind == .shell {
            return title
        }
        if tab.kind == .shell { return (tab.cwd as NSString).lastPathComponent }
        if tab.kind == .agent { return (agent(of: tab)?.name ?? "agent").lowercased() }
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

    /// Writes the state file. On failure (a full disk, lost permissions) it says so in the status bar with
    /// a Retry, rather than looking saved; returns whether it worked.
    @discardableResult
    func save() -> Bool {
        var snapshot = groups
        for g in snapshot.indices {
            snapshot[g].tabs.removeAll { $0.transient == true }
            snapshot[g].splitPanes = nil
        }
        let state = SavedState(groups: snapshot, selectedGroupID: selectedGroupID, settings: settings,
                               viewerOpens: viewerOpenCounts.isEmpty ? nil : viewerOpenCounts,
                               viewerOpenedAt: viewerOpenedAt.isEmpty ? nil : viewerOpenedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(state)
            // Private to you: startup commands can hold tokens.
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            if saveError != nil { saveError = nil; DebugLog.log("state saved again", "app") }
            return true
        } catch {
            if saveError == nil { DebugLog.log("couldn't save state: \(error.localizedDescription)", "app") }
            saveError = error.localizedDescription
            return false
        }
    }

    private var backedUpUnreadableState = false

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
        var dropped = 0, migrated = false
        // Every value that isn't what it should be counts, so any lossy load keeps the original.
        let rawGroups = SavedStateList.items(object["groups"], dropped: &dropped)
        for raw in rawGroups {
            guard var rawGroup = raw as? [String: Any] else { dropped += 1; continue }
            let rawTabs = SavedStateList.items(rawGroup["tabs"], dropped: &dropped)
            rawGroup["tabs"] = []
            guard let groupData = try? JSONSerialization.data(withJSONObject: rawGroup),
                  var group = try? decoder.decode(GroupModel.self, from: groupData) else { dropped += 1; continue }
            group.tabs = rawTabs.compactMap { raw in
                guard var raw = raw as? [String: Any] else { dropped += 1; return nil }
                if SavedStateMigration.tab(&raw) { migrated = true }
                guard let tabData = try? JSONSerialization.data(withJSONObject: raw),
                      var tab = try? decoder.decode(TabModel.self, from: tabData) else { dropped += 1; return nil }
                tab.adoptLegacyWorkstream()
                return tab
            }
            groups.append(group)
        }
        viewerOpenCounts = object["viewerOpens"] as? [String: Int] ?? [:]
        viewerOpenedAt = (object["viewerOpenedAt"] as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSinceReferenceDate: $0) }
        if let selected = object["selectedGroupID"] as? String, let id = UUID(uuidString: selected),
           groups.contains(where: { $0.id == id }) {
            selectedGroupID = id
        } else {
            selectedGroupID = groups.first?.id
        }
        if var raw = object["settings"] as? [String: Any] {
            if SavedStateMigration.settings(&raw) { migrated = true }
            if let settingsData = try? JSONSerialization.data(withJSONObject: raw) {
                settings = AgentDESettings.decodeLenient(from: settingsData)
            }
        }
        if dropped > 0 { backUpUnreadableState("\(dropped) group(s) or tab(s) couldn't be read") }
        // State from before agents were one kind of tab: the original is kept once, before it's ever overwritten.
        if migrated {
            let backup = stateURL.appendingPathExtension("pre-agents")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: stateURL, to: backup)
                DebugLog.log("saved state migrated to agent tabs; the original is kept as \(backup.lastPathComponent)", "state")
            }
        }
    }

    private func backUpUnreadableState(_ reason: String) {
        guard !backedUpUnreadableState else { return }
        backedUpUnreadableState = true
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = stateURL.deletingLastPathComponent().appendingPathComponent("state.json.unreadable-\(stamp)")
        try? FileManager.default.copyItem(at: stateURL, to: backup)
        DebugLog.log("saved state: \(reason); kept the original as \(backup.lastPathComponent)", "state")
    }

    private func settingsChanged(from old: AgentDESettings) {
        if old.fontName != settings.fontName || old.fontSize != settings.fontSize
            || old.theme != settings.theme || old.appearance != settings.appearance {
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

/// A list in saved state: missing or null is an empty list; anything else that isn't a list is a loss.
enum SavedStateList {
    static func items(_ value: Any?, dropped: inout Int) -> [Any] {
        if let list = value as? [Any] { return list }
        if value != nil, !(value is NSNull) { dropped += 1 }
        return []
    }
}
