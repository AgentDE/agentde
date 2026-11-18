import AppKit

/// A session you started and named that was active recently, offered as a one-click resume under its group.
struct RecentSession: Identifiable, Equatable, Codable {
    var id: String { sessionId }
    let sessionId: String
    let name: String
    let cwd: String
    let lastActive: Date
    /// Its agent's id ("claude", "codex").
    var agent: String = ClaudeAgent.id
}

extension Store {
    /// Recent sessions that ran in exactly this group's folder and aren't already open in a tab or pinned.
    func recentSessions(for group: GroupModel) -> [RecentSession] {
        sessions(recentSessions, for: group)
    }

    /// The same, from before `recentSessionDays`; nil until they've been scanned.
    func olderSessions(for group: GroupModel) -> [RecentSession]? {
        olderSessions.map { sessions($0, for: group) }
    }

    /// The group's pinned sessions that aren't open in a tab, each with its latest name and time if a
    /// scan has seen it since it was pinned.
    func pinnedSessions(for group: GroupModel) -> [RecentSession] {
        let open = openSessionIds
        let latest = Dictionary((recentSessions + (olderSessions ?? [])).map { ($0.sessionId, $0) }) { a, _ in a }
        return (group.pinnedSessions ?? []).filter { !open.contains($0.sessionId) }.map { latest[$0.sessionId] ?? $0 }
    }

    func isPinned(_ session: RecentSession, in groupID: UUID) -> Bool {
        groups.first { $0.id == groupID }?.pinnedSessions?.contains { $0.sessionId == session.sessionId } ?? false
    }

    /// Pins a session to the top of the group's list, or unpins it.
    /// Stops a session that's running as a background agent with no tab (Recent's radio-waves entries), after
    /// asking: it may be mid-task. `claude stop` keeps the conversation, so it can be resumed later.
    func stopLiveBackgroundSession(_ session: RecentSession, job: String) {
        guard confirm("Stop \(session.name)?",
                      detail: "This background agent will stop, even if it's in the middle of a task. The conversation is kept, so you can resume it later.",
                      button: "Stop Agent") else { return }
        DebugLog.log("stopping background session \(session.sessionId.prefix(8)) (job \(job)) from Recent", "agent")
        stopBackgroundJob(job)
    }

    func togglePinned(_ session: RecentSession, in groupID: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let pinned = Self.togglingPin(session, in: groups[g].pinnedSessions ?? [])
        groups[g].pinnedSessions = pinned.isEmpty ? nil : pinned
        scheduleSave()
    }

    /// The agent session a tab runs, as a session to pin; nil for tabs without one (shells).
    func pinnableSession(_ tab: TabModel) -> RecentSession? {
        guard let id = tab.agentSession else { return nil }
        return RecentSession(sessionId: id, name: title(for: tab), cwd: tab.cwd, lastActive: Date(),
                             agent: agent(of: tab)?.id ?? ClaudeAgent.id)
    }

    func isPinned(tab: TabModel, in groupID: UUID) -> Bool {
        pinnableSession(tab).map { isPinned($0, in: groupID) } ?? false
    }

    /// Pins an open tab's session: the tab moves up, below any tabs already pinned, and once closed the
    /// session stays at the top of the group's session list. Unpinning drops the pin and leaves the tab in place.
    func togglePinnedTab(_ id: UUID) {
        guard let (g, t) = locate(id), let session = pinnableSession(groups[g].tabs[t]) else { return }
        let groupID = groups[g].id
        let pinning = !isPinned(session, in: groupID)
        togglePinned(session, in: groupID)
        guard pinning else { return }
        let tab = groups[g].tabs.remove(at: t)
        let pinnedAbove = groups[g].tabs.prefix { isPinned(tab: $0, in: groupID) }.count
        groups[g].tabs.insert(tab, at: pinnedAbove)
        scheduleSave()
    }

    /// `pinned` with `session` removed if it's there, otherwise added at the top.
    static func togglingPin(_ session: RecentSession, in pinned: [RecentSession]) -> [RecentSession] {
        pinned.contains { $0.sessionId == session.sessionId }
            ? pinned.filter { $0.sessionId != session.sessionId } : [session] + pinned
    }

    private var openSessionIds: Set<String> {
        Set(groups.flatMap { $0.tabs.compactMap(\.agentSession) })
    }

    private func sessions(_ all: [RecentSession], for group: GroupModel) -> [RecentSession] {
        Self.sessions(all, for: group, in: groups, open: openSessionIds)
    }

    /// A folder's sessions belong to the first group (from the top of the sidebar) with that folder, so a second
    /// group started in the same folder doesn't list them again. Pinned or open sessions aren't listed.
    static func sessions(_ all: [RecentSession], for group: GroupModel, in groups: [GroupModel], open: Set<String>) -> [RecentSession] {
        let dir = normalized(group.dir)
        let sameFolder = groups.filter { normalized($0.dir) == dir }
        guard sameFolder.first?.id ?? group.id == group.id else { return [] }
        let pinned = sameFolder.flatMap { ($0.pinnedSessions ?? []).map(\.sessionId) }
        let hidden = open.union(pinned)
        return all.filter { !hidden.contains($0.sessionId) && normalized($0.cwd) == dir }
    }

    /// Every session Jump to finds under a group: Recent's and Older's, plus those that ran in a folder inside the
    /// group's (a worktree, say), which belong to the group with the deepest folder that holds them (the first
    /// in the sidebar on a tie). Open and pinned sessions aren't listed; a group's pins are searched on their own.
    static func searchable(_ all: [RecentSession], for group: GroupModel, in groups: [GroupModel], open: Set<String>) -> [RecentSession] {
        let pinned = groups.flatMap { ($0.pinnedSessions ?? []).map(\.sessionId) }
        let hidden = open.union(pinned)
        let dirs = groups.map { normalized($0.dir) }
        return all.filter { session in
            guard !hidden.contains(session.sessionId) else { return false }
            let cwd = normalized(session.cwd)
            var owner: Int?
            for (i, dir) in dirs.enumerated() where cwd == dir || cwd.hasPrefix(dir == "/" ? dir : dir + "/") {
                if owner == nil || dir.count > dirs[owner!].count { owner = i }
            }
            return owner.map { groups[$0].id } == group.id
        }
    }

    /// `searchable` for one group, from what the scans found so far.
    func searchableSessions(for group: GroupModel) -> [RecentSession] {
        Self.searchable(recentSessions + (olderSessions ?? []), for: group, in: groups, open: openSessionIds)
    }

    /// Opens or closes a group's Older list; opening it rescans (the scanners cache what hasn't changed).
    func toggleOlderShown(_ id: UUID) {
        if olderShown.remove(id) == nil {
            olderShown.insert(id)
            loadOlderSessions()
        }
    }

    /// Scans for older sessions in the background (cached by the scanners), so each group knows whether it
    /// has any and shows its Older fold. Runs once shortly after launch, and again whenever a fold opens.
    func loadOlderSessions() {
        let days = settings.recentSessionDays, codex = settings.showCodexSessions
        OlderSessionScan.queue.async { [weak self] in
            let cutoff = Date().addingTimeInterval(-days * 86_400)
            let all = OlderSessionScan.scanners.filter { codex || $0.agent != CodexAgent.id }
                .flatMap { $0.scanner.scan(days: OlderSessionScan.days) }
            let older = all.filter { $0.lastActive < cutoff }.sorted { $0.lastActive > $1.lastActive }
            DispatchQueue.main.async { self?.olderSessions = older }
        }
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The folder a session resumes in: its own, or, when that's gone (a removed worktree, say), one you
    /// pick: never a silent substitute, since the agent would run in another repository.
    private func folderToResume(_ session: RecentSession) -> String? {
        if TerminalSession.canEnter(folder: session.cwd) { return session.cwd }
        let alert = NSAlert()
        alert.messageText = "\(session.name)'s folder is gone"
        alert.informativeText = "\(session.cwd.abbreviatingHome) no longer exists. Choose where to resume it."
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: session.cwd).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    func resumeRecentSession(_ session: RecentSession, in groupID: UUID) {
        guard let cwd = folderToResume(session) else { return }
        // Already running as a background session (Claude's): attach to it rather than starting a second copy.
        if let job = Agents.byID(session.agent)?.liveBackgroundJob(session: session.sessionId, store: self) {
            if let id = newAgentTab(session.agent, in: groupID, session: session.sessionId, cwd: cwd, attachJobId: job) {
                coverWhileResuming(id, name: session.name)
            }
            return
        }
        if liveSessionIds.contains(session.sessionId) {
            let alert = NSAlert()
            alert.messageText = "\(session.name) is running somewhere else"
            alert.informativeText = "Resuming it here makes two copies of the same session. Close the other one first, or open it anyway."
            alert.addButton(withTitle: "Open anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if let id = newAgentTab(session.agent, in: groupID, session: session.sessionId, cwd: cwd), let (g, t) = locate(id) {
            groups[g].tabs[t].lastAgentName = session.name
            scheduleSave()
            coverWhileResuming(id, name: session.name)
        }
    }

    /// Covers a tab that's resuming a session (`LoadingCover`) until `ResumeCover` says the agent is ready.
    func coverWhileResuming(_ id: UUID, name: String) {
        resumingTabs[id] = name
        let started = Date()
        func check() {
            guard resumingTabs[id] != nil else { return }
            let session = terminals.session(id)
            let prompt = tab(id).flatMap { agent(of: $0)?.definition.prompt?.first }
            let elapsed = Date().timeIntervalSince(started)
            if tab(id) == nil || ResumeCover.done(elapsed: elapsed, quietFor: session?.lastOutputAt.map { Date().timeIntervalSince($0) },
                                                  promptOnScreen: prompt.map { session?.inputHasDraft(prompt: $0) != nil }) {
                DebugLog.log("tab \(id.uuidString.prefix(8)) resumed in \(Int(elapsed * 1000)) ms", "agent")
                resumingTabs[id] = nil
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
    }
}

/// When a resuming tab's cover comes off: once the agent's input line is on screen and its output has settled
/// (the conversation drawn), or, for an agent with no known input line, once output has been quiet a while.
/// Never later than `limit`, so a resume that fails (back at the shell) doesn't stay covered.
enum ResumeCover {
    static let limit: TimeInterval = 20

    /// `quietFor`: how long since the terminal's last output, nil before any. `promptOnScreen`: whether the
    /// agent's input line is showing, nil when the agent has none we know.
    static func done(elapsed: TimeInterval, quietFor: TimeInterval?, promptOnScreen: Bool?) -> Bool {
        if elapsed >= limit { return true }
        guard let quietFor else { return false }
        if let promptOnScreen { return promptOnScreen && quietFor >= 0.4 }
        return elapsed >= 2 && quietFor >= 1
    }
}

/// The Older lists' own scanners, used only on their queue, so their caches outlive one scan.
private enum OlderSessionScan {
    static let queue = DispatchQueue(label: "older-sessions", qos: .utility)
    static let scanners = Agents.all.compactMap { agent in agent.sessionScanner().map { (agent: agent.id, scanner: $0) } }
    /// As far back as transcripts go: Claude Code deletes them after `cleanupPeriodDays` (30 unless set).
    static let days: Double = 3650
}
