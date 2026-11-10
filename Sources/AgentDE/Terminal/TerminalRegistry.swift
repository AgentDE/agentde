import AppKit

/// Owns every tab's terminal session, browser and viewer, keyed by tab id.
final class TerminalRegistry {
    weak var store: Store?
    private var sessions: [UUID: TerminalSession] = [:]
    /// Closed tabs whose terminal was still starting, kept until they've ended what they started.
    private var retiring: [UUID: TerminalSession] = [:]
    let browsers = BrowserRegistry()
    let viewers = ViewerRegistry()
    private var explorers: [UUID: FileExplorerModel] = [:]

    func existingExplorer(_ id: UUID) -> FileExplorerModel? { explorers[id] }

    /// The tab's explorer, rooted at its folder; a tab whose folder changed (Claude moved into a worktree,
    /// say) gets a new one there rather than the old folder's tree.
    func explorer(for tab: TabModel) -> FileExplorerModel {
        if let existing = explorers[tab.id], existing.root.path == URL(fileURLWithPath: tab.cwd).path { return existing }
        let model = FileExplorerModel(root: tab.cwd, selection: tab.explorerSelection)
        explorers[tab.id] = model
        return model
    }

    func session(for tab: TabModel) -> TerminalSession {
        if let existing = sessions[tab.id] { return existing }
        let session = TerminalSession(tabID: tab.id, store: store!)
        sessions[tab.id] = session
        return session
    }

    func session(_ id: UUID) -> TerminalSession? { sessions[id] }

    var retiringCount: Int { retiring.count }

    var shellPids: [pid_t: UUID] {
        var map: [pid_t: UUID] = [:]
        for (id, session) in sessions where session.shellPid > 0 { map[session.shellPid] = id }
        return map
    }

    func focus(_ id: UUID) {
        guard let view = sessions[id]?.view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func terminate(_ id: UUID) {
        if let session = sessions[id] {
            retiring[id] = session
            session.onRetired = { [weak self] in self?.retiring[id] = nil }
            session.terminate()
            session.view.removeFromSuperview()
        }
        sessions[id] = nil
        browsers.remove(id)
        viewers.remove(id)
        explorers[id] = nil
    }

    /// Ends a tab's shell (like closing it) but keeps the tab's browser, viewer and explorer, and puts a new,
    /// held terminal session in its place. It starts only once `held` is cleared, after the old holder is gone,
    /// so it can't reconnect to the dying one.
    func replaceTerminal(_ id: UUID) -> TerminalSession {
        if let old = sessions[id] {
            retiring[id] = old
            old.onRetired = { [weak self] in self?.retiring[id] = nil }
            old.terminate()
            old.view.removeFromSuperview()
        }
        let session = TerminalSession(tabID: id, store: store!)
        session.held = true
        sessions[id] = session
        return session
    }

    /// Sends raw bytes (a control key, say) to a tab's program, as if typed.
    func sendKey(_ id: UUID, _ bytes: [UInt8]) {
        sessions[id]?.view.send(data: bytes[...])
    }

    func applyAppearance() {
        for session in sessions.values { session.applyAppearance() }
    }

    /// Output bytes per started terminal since the last call, for the heartbeat.
    func takeOutputCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for (id, session) in sessions where session.started { counts[id] = session.takeOutputCount() }
        return counts
    }

    /// Types text into a tab as if from the keyboard. A trailing "\r" is sent separately after a pause,
    /// so TUIs like Claude Code treat it as Enter rather than part of a paste.
    @discardableResult
    func typeIntoTerminal(_ id: UUID, _ text: String) -> Bool {
        guard let session = sessions[id], session.started, session.acceptsInput else { return false }
        let view = session.view
        let submit = text.hasSuffix("\r")
        // Control characters (newlines, escapes) in file names or check names must never act as keys.
        let body = (submit ? String(text.dropLast()) : text).unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        view.send(txt: String(String.UnicodeScalarView(body)))
        if submit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { view.send(txt: "\r") }
        }
        return true
    }
}

extension Store {
    /// At launch, reconnects every tab whose holder is still running, so agents that kept
    /// working while AgentDE was closed show their status right away. Holders that belong to no tab are
    /// only logged: the state file may be wrong, and what they run may matter.
    func reattachRunningTabs() {
        guard PtyHost.prepareDirectory() else {
            DebugLog.log("terminal holder folder \(PtyHost.directory) isn't usable", "tab")
            return
        }
        let running = Set(PtyHost.holderIDs())
        if Store.adoptLegacyDrawers(&groups, running: running) { scheduleSave() }
        var known = Set<UUID>()
        for group in groups {
            for tab in group.tabs {
                known.insert(tab.id)
                if running.contains(tab.id) { terminals.session(for: tab).reattachIfRunning() }
            }
        }
        let orphans = running.subtracting(known)
        if !orphans.isEmpty {
            DebugLog.log("terminal holders with no tab: " + orphans.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ", "), "tab")
        }
    }
}

extension Store {
    /// Shell drawers from earlier versions: a drawer whose shell is still running in its holder becomes an
    /// ordinary shell tab right after its owner, with the same id so it reattaches to that holder. Drawers
    /// with nothing running are dropped. Returns whether anything changed.
    static func adoptLegacyDrawers(_ groups: inout [GroupModel], running: Set<UUID>) -> Bool {
        var changed = false
        for g in groups.indices {
            var t = 0
            while t < groups[g].tabs.count {
                let owner = groups[g].tabs[t]
                if owner.companionID != nil || owner.showShell != nil {
                    groups[g].tabs[t].companionID = nil
                    groups[g].tabs[t].showShell = nil
                    changed = true
                    if let companion = owner.companionID, running.contains(companion),
                       !groups.contains(where: { $0.tabs.contains { $0.id == companion } }) {
                        groups[g].tabs.insert(TabModel(id: companion, kind: .shell, cwd: owner.cwd), at: t + 1)
                        DebugLog.log("shell drawer \(companion.uuidString.prefix(8)) of tab \(owner.id.uuidString.prefix(8)) is now its own tab", "tab")
                        t += 1
                    }
                }
                t += 1
            }
        }
        return changed
    }
}
