import AppKit

extension Store {
    /// Recent sessions that ran in exactly this group's folder and aren't already open in a tab.
    func recentSessions(for group: GroupModel) -> [RecentSession] {
        let open = Set(groups.flatMap { $0.tabs.flatMap { [$0.claudeSessionId, $0.codexSessionId].compactMap { $0 } } })
        let dir = Self.normalized(group.dir)
        return recentSessions.filter { !open.contains($0.sessionId) && Self.normalized($0.cwd) == dir }
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
