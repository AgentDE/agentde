import AppKit

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
    func togglePinned(_ session: RecentSession, in groupID: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let pinned = Self.togglingPin(session, in: groups[g].pinnedSessions ?? [])
        groups[g].pinnedSessions = pinned.isEmpty ? nil : pinned
        scheduleSave()
    }

    /// The Claude or Codex session a tab runs, as a session to pin; nil for tabs without one (shells).
    func pinnableSession(_ tab: TabModel) -> RecentSession? {
        guard let id = tab.claudeSessionId ?? tab.codexSessionId else { return nil }
        return RecentSession(sessionId: id, name: title(for: tab), cwd: tab.cwd, lastActive: Date(),
                             agent: tab.claudeSessionId == nil ? .codex : .claude)
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
        Set(groups.flatMap { $0.tabs.flatMap { [$0.claudeSessionId, $0.codexSessionId].compactMap { $0 } } })
    }

    private func sessions(_ all: [RecentSession], for group: GroupModel) -> [RecentSession] {
        let hidden = openSessionIds.union((group.pinnedSessions ?? []).map(\.sessionId))
        let dir = Self.normalized(group.dir)
        return all.filter { !hidden.contains($0.sessionId) && Self.normalized($0.cwd) == dir }
    }

    /// Opens or closes a group's Older list; opening it rescans (the scanners cache what hasn't changed).
    func toggleOlderShown(_ id: UUID) {
        if olderShown.remove(id) == nil {
            olderShown.insert(id)
            loadOlderSessions()
        }
    }

    private func loadOlderSessions() {
        let days = settings.recentSessionDays, codex = settings.showCodexSessions
        OlderSessionScan.queue.async { [weak self] in
            let cutoff = Date().addingTimeInterval(-days * 86_400)
            let all = OlderSessionScan.claude.scan(days: OlderSessionScan.days)
                + (codex ? OlderSessionScan.codex.scan(days: OlderSessionScan.days) : [])
            let older = all.filter { $0.lastActive < cutoff }.sorted { $0.lastActive > $1.lastActive }
            DispatchQueue.main.async { self?.olderSessions = older }
        }
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func resumeRecentSession(_ session: RecentSession, in groupID: UUID) {
        let cwd = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : nil
        if session.agent == .codex {
            if let id = newTab(kind: .codex, in: groupID, cwd: cwd), let (g, t) = locate(id) {
                groups[g].tabs[t].codexSessionId = session.sessionId
                groups[g].tabs[t].lastAgentName = session.name
                scheduleSave()
            }
            return
        }
        // Already running as a background session: attach to it rather than starting a second copy.
        if let job = liveBackgroundJobs[session.sessionId] {
            newTab(kind: .claude, in: groupID, sessionId: session.sessionId, cwd: cwd, attachJobId: job)
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
        if let id = newTab(kind: .claude, in: groupID, sessionId: session.sessionId, cwd: cwd), let (g, t) = locate(id) {
            groups[g].tabs[t].lastAgentName = session.name
        }
    }
}

/// The Older lists' own scanners, used only on their queue, so their caches outlive one scan.
private enum OlderSessionScan {
    static let queue = DispatchQueue(label: "older-sessions", qos: .utility)
    static let claude = RecentSessionScanner()
    static let codex = CodexSessionScanner()
    /// As far back as transcripts go: Claude Code deletes them after `cleanupPeriodDays` (30 unless set).
    static let days: Double = 3650
}
