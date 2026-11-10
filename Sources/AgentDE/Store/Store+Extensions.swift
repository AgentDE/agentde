import AppKit
import SwiftUI

/// The app as native extensions see it (`AgentDEHost`), and the helpers that call their hooks.
extension Store: AgentDEHost {
    var allTabs: [TabInfo] { groups.flatMap { group in group.tabs.map { info($0, in: group) } } }

    var allGroups: [GroupInfo] { groups.map { GroupInfo(id: $0.id, name: $0.name, folder: $0.dir) } }

    func tabInfo(_ id: UUID) -> TabInfo? {
        guard let (g, t) = locate(id) else { return nil }
        return info(groups[g].tabs[t], in: groups[g])
    }

    func info(_ tab: TabModel, in group: GroupModel) -> TabInfo {
        let rt = runtime[tab.id]
        return TabInfo(id: tab.id, groupID: group.id, kind: tab.kind, folder: tab.cwd, groupFolder: group.dir, title: title(for: tab),
                       agentSession: agentSession(of: tab), agentPresent: rt?.agentPresent ?? false, state: rt?.state ?? .none,
                       viewerItem: tab.viewerItem)
    }

    /// The agent session a tab runs (Claude, or Codex). None yet for a fork that hasn't started: it holds its
    /// parent's id until Claude gives it its own.
    func agentSession(of tab: TabModel) -> String? {
        if tab.forkOnStart == true { return nil }
        return (tab.kind == .codex ? tab.codexSessionId : tab.claudeSessionId).flatMap(SafeID.session)
    }

    var activeTabID: UUID? { activeTab?.id }
    var liveSessions: Set<String> { liveSessionIds }
    var rateLimitsUsed: (fiveHour: Double?, sevenDay: Double?) { (rateLimits.fiveHour, rateLimits.sevenDay) }
    var animations: Bool { settings.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }


    @discardableResult
    func type(_ text: String, into tab: UUID) -> Bool { terminals.typeIntoTerminal(tab, text) }

    @discardableResult
    func openTab(kind: TabKind, in group: UUID, folder: String?, title: String?) -> UUID? {
        guard let id = newTab(kind: kind, in: group, cwd: folder) else { return nil }
        if let title, let (g, t) = locate(id) {
            groups[g].tabs[t].customTitle = title
            scheduleSave()
        }
        return id
    }

    func value(_ key: String, tab: UUID, for ext: AgentDEExtension) -> String? {
        guard let (g, t) = locate(tab) else { return nil }
        return groups[g].tabs[t].extensionData?[ext.id + "." + key]
    }

    func setValue(_ value: String?, _ key: String, tab: UUID, for ext: AgentDEExtension) {
        guard let (g, t) = locate(tab), groups[g].tabs[t].extensionData?[ext.id + "." + key] != value else { return }
        var data = groups[g].tabs[t].extensionData ?? [:]
        data[ext.id + "." + key] = value
        groups[g].tabs[t].extensionData = data.isEmpty ? nil : data
        scheduleSave()
    }

    func settingsData(for ext: AgentDEExtension) -> Data? {
        settings.extensionSettings?[ext.id].map { Data($0.utf8) }
    }

    func setSettingsData(_ data: Data?, for ext: AgentDEExtension) {
        var all = settings.extensionSettings ?? [:]
        all[ext.id] = data.map { String(decoding: $0, as: UTF8.self) }
        settings.extensionSettings = all.isEmpty ? nil : all
    }

    func showProblem(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    var configDirectory: URL { URL(fileURLWithPath: AppBrand.configDirectory) }

    // MARK: Calling hooks

    func startExtensions() {
        ViewerLinks.rules = [ViewerLinks.claude] + linkRules
        Theme.all = Theme.builtIn + themeDefinitions
        GroupPalette.all = GroupPalette.builtIn + paletteDefinitions
        for ext in extensions { ext.start(host: self) }
    }

    func stopExtensions() {
        for ext in extensions { ext.stop() }
    }

    /// Sessions running anywhere on this Mac, after each registry poll.
    func updateLiveSessions(_ live: Set<String>) {
        if live != liveSessionIds { liveSessionIds = live }
        for ext in extensions { ext.liveSessionsChanged(live) }
    }

    func agentSessionsChanged() {
        for ext in extensions { ext.agentSessionsChanged() }
    }

    /// Whether any extension wants this tab's attention ring.
    func wantsAttention(_ tab: TabModel) -> Bool {
        guard !extensions.isEmpty, let info = tabInfo(tab.id) else { return false }
        return extensions.contains { $0.wantsAttention(info) }
    }

    func launchEnvironment(for tabID: UUID) -> [String: String] {
        guard let info = tabInfo(tabID) else { return [:] }
        return extensions.reduce(into: [:]) { env, ext in env.merge(ext.launchEnvironment(for: info)) { $1 } }
    }

    /// The side panel's tabs for a terminal tab: the extensions' (Workstream, say), then Files and Changes.
    func sidePanelTabs(for tab: TabModel) -> [SidePanelTab] {
        guard tab.kind != .files, tab.kind != .command, let info = tabInfo(tab.id) else { return [] }
        return extensions.flatMap { $0.sidePanelTabs(for: info) } + [
            SidePanelTab(id: "files", title: "Files", symbol: "folder", view: AnyView(FilesPanel(tab: tab))),
            SidePanelTab(id: "changes", title: "Changes", symbol: "plusminus", view: AnyView(ChangesPanel(tab: tab))),
        ]
    }

    /// Whether a tab shows its side panel: what the user chose (⌥⌘I), else shown when an extension adds a tab
    /// to it (the workstream), else hidden.
    func panelVisible(_ tab: TabModel) -> Bool {
        guard tab.kind != .files, tab.kind != .command else { return false }
        if let hidden = tab.panelHidden { return !hidden }
        guard let info = tabInfo(tab.id) else { return false }
        return extensions.contains { !$0.sidePanelTabs(for: info).isEmpty }
    }

    var linkRules: [LinkRule] { extensions.flatMap(\.linkRules) }
    var themeDefinitions: [ThemeDefinition] { extensions.flatMap(\.themes) }
    var paletteDefinitions: [PaletteDefinition] { extensions.flatMap(\.palettes) }
}
