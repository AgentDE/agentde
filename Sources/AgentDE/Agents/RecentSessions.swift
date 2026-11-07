import AppKit

extension Store {
    /// Recent sessions that ran in exactly this group's folder and aren't already open in a tab.
    func recentSessions(for group: GroupModel) -> [RecentSession] {
        sessions(recentSessions, for: group)
    }

    /// The same, from before `recentSessionDays`; nil until they've been scanned.
    func olderSessions(for group: GroupModel) -> [RecentSession]? {
        olderSessions.map { sessions($0, for: group) }
    }

    private func sessions(_ all: [RecentSession], for group: GroupModel) -> [RecentSession] {
        let open = Set(groups.flatMap { $0.tabs.flatMap { [$0.claudeSessionId, $0.codexSessionId].compactMap { $0 } } })
        let dir = Self.normalized(group.dir)
        return all.filter { !open.contains($0.sessionId) && Self.normalized($0.cwd) == dir }
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
    /// As far back as transcripts go (Claude Code deletes old ones itself).
    static let days: Double = 3650
}
