import AppKit

/// Opening, closing, renaming and moving tabs; the browser pane; editor and diff actions.
extension Store {
    /// A new shell, File Explorer or command tab, after the selected one.
    @discardableResult
    func newTab(kind: TabKind, in groupID: UUID? = nil, command: String? = nil, transient: Bool = false,
                cwd: String? = nil) -> UUID? {
        guard let g = groups.firstIndex(where: { $0.id == (groupID ?? selectedGroupID) }) else { return nil }
        let cwd = cwd ?? (groupID == nil ? activeTab?.cwd : nil) ?? groups[g].dir
        return insertTab(TabModel(kind: kind, cwd: cwd, command: command, transient: transient ? true : nil), in: g)
    }

    /// A new tab running agent `agentID`: resuming `session` when given, or attached to background job `attachJobId`.
    @discardableResult
    func newAgentTab(_ agentID: String, in groupID: UUID? = nil, session: String? = nil, cwd: String? = nil,
                     attachJobId: String? = nil) -> UUID? {
        guard let g = groups.firstIndex(where: { $0.id == (groupID ?? selectedGroupID) }) else { return nil }
        var tab = TabModel.agent(agentID, cwd: cwd ?? (groupID == nil ? activeTab?.cwd : nil) ?? groups[g].dir, session: session)
        tab.attachJobId = attachJobId
        return insertTab(tab, in: g)
    }

    private func insertTab(_ tab: TabModel, in g: Int) -> UUID {
        DebugLog.log("new tab \(tab.id.uuidString.prefix(8)) kind=\(tab.kind.rawValue)" + (tab.agentID.map { " agent=\($0)" } ?? "")
                     + " group=\(groups[g].name)" + (tab.agentSession.map { " session=\($0.prefix(8))" } ?? "")
                     + (tab.attachJobId.map { " attach=\($0)" } ?? ""), "tab")
        let insertAt = (groups[g].tabs.firstIndex { $0.id == groups[g].selectedTabID }).map { $0 + 1 } ?? groups[g].tabs.count
        groups[g].tabs.insert(tab, at: insertAt)
        selectTab(tab.id)
        return tab.id
    }

    /// A new agent tab from a menu, key or button: it asks for a name first when Settings → Terminal says so
    /// (Return starts it; an empty name starts it unnamed; Cancel opens nothing). The name titles the tab, and an
    /// agent that names its sessions (Claude's `--name`) gets it too.
    @discardableResult
    func startTab(agent agentID: String, in groupID: UUID? = nil) -> UUID? {
        guard let agent = Agents.byID(agentID) else { return nil }
        var name: String?
        if settings.askSessionName {
            let alert = NSAlert()
            alert.messageText = "Name this \(agent.name) session"
            alert.informativeText = agent.namesSessions
                ? "It shows on the tab, in Recent and in \(agent.name)'s resume list. Leave it empty to skip."
                : "It shows on the tab. Leave it empty to skip."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "fix login"
            alert.accessoryView = field
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        }
        guard let id = newAgentTab(agentID, in: groupID) else { return nil }
        if let name, !name.isEmpty, let (g, t) = locate(id) {
            groups[g].tabs[t].customTitle = name
            if agent.namesSessions { groups[g].tabs[t].sessionName = name }
            scheduleSave()
        }
        return id
    }

    /// What New tab starts by default (Settings → Terminal): an agent, or a shell.
    @discardableResult
    func startDefaultTab(in groupID: UUID? = nil) -> UUID? {
        Agents.byID(settings.defaultAgent) != nil ? startTab(agent: settings.defaultAgent, in: groupID)
            : newTab(kind: .shell, in: groupID)
    }

    /// Closes a tab, stopping its agent (a background session's too); the conversation is kept. To leave an
    /// agent running out of view, send its tab to the background instead.
    func closeTab(_ id: UUID, confirmIfBusy: Bool = true) {
        guard let tab = tab(id) else { return }
        if confirmIfBusy, state(id) == .working,
           !confirm("Stop a working agent?", detail: "\(title(for: tab)) is still running a turn, and closing stops it. "
                    + "The conversation is kept, so you can resume it from Recent.", button: "Close & Stop Agent") {
            return
        }
        // The alert ran the event loop, so the tab may have moved or gone: look it up again.
        guard let (g, t) = locate(id) else { return }
        rememberClosed(groups[g].tabs[t], group: groups[g].id, at: t)
        dispose(groups[g].tabs[t])
        let wasSelected = groups[g].selectedTabID == id
        groups[g].tabs.remove(at: t)
        if wasSelected { groups[g].selectedTabID = Store.neighbor(of: t, in: groups[g]) }
        scheduleSave()
        focusActiveTerminal()
    }

    /// Takes a tab out of view (the tab strip, a split) and leaves what runs in it running: its holder keeps
    /// the agent going, it still reports its status, and the sidebar lists it under the group's Background.
    /// Choosing it again (sidebar, ⌘J, a notification) brings it back.
    func sendToBackground(_ id: UUID) {
        guard let (g, t) = locate(id), groups[g].tabs[t].background != true else { return }
        groups[g].tabs[t].background = true
        if let layout = groups[g].layout {
            groups[g].layout = layout.removing(id).flatMap { $0.tabs.count >= 2 ? $0 : nil }
        }
        if groups[g].selectedTabID == id { groups[g].selectedTabID = Store.neighbor(of: t, in: groups[g]) }
        DebugLog.log("tab \(id.uuidString.prefix(8)) sent to the background", "tab")
        scheduleSave()
        focusActiveTerminal()
    }

    /// The shown tab to select after the one at `index` leaves view: the next one, else the one before.
    static func neighbor(of index: Int, in group: GroupModel) -> UUID? {
        let shown = group.tabs.enumerated().filter { $0.element.background != true && $0.offset != index }
        return (shown.first { $0.offset > index } ?? shown.last)?.element.id
    }

    /// The last few closed tabs, newest last, for Reopen Closed Tab (this run only).
    struct ClosedTab { var tab: TabModel; var group: UUID; var index: Int }

    private func rememberClosed(_ tab: TabModel, group: UUID, at index: Int) {
        guard tab.transient != true, tab.kind != .command else { return }
        closedTabs.append(ClosedTab(tab: tab, group: group, index: index))
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    }

    /// Brings back the last closed tab where it was: its folder (a worktree too), its session (resumed, since
    /// closing stopped the agent), title, viewer and panel. Its terminal starts fresh.
    func reopenClosedTab(waited: Int = 0) {
        // Its background job is still being stopped, or still listed as running: wait (up to 10 s), so the
        // session isn't attached to a job that's exiting, nor resumed beside one that's still alive.
        if let last = closedTabs.last, let job = last.tab.attachJobId, waited < 50,
           stoppingJobs.contains(job) || (liveBackgroundJobs.values.contains(job) && !failedStops.contains(job)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reopenClosedTab(waited: waited + 1) }
            return
        }
        while let closed = closedTabs.popLast() {
            guard let g = groups.firstIndex(where: { $0.id == closed.group }) ?? groups.indices.first else { continue }
            var tab = closed.tab
            tab.id = UUID()
            tab.forkOnStart = nil
            tab.background = nil
            // A stopped background session resumes in the tab, unless it's still live (stopping can lag, or failed):
            // then the tab attaches to it rather than start a second copy.
            let original = closed.tab.attachJobId
            if let original, liveBackgroundJobs.values.contains(original) {
                tab.attachJobId = original
                DebugLog.log("reopen: background job \(original) is still running; attaching to it", "tab")
            } else {
                tab.attachJobId = tab.agentSession.flatMap { liveBackgroundJobs[$0] }.flatMap { stoppingJobs.contains($0) ? nil : $0 }
            }
            if tab.kind == .shell, tab.agentSession == nil { tab.lastAgentName = nil }
            groups[g].tabs.insert(tab, at: min(closed.index, groups[g].tabs.count))
            DebugLog.log("reopened closed tab as \(tab.id.uuidString.prefix(8)) kind=\(tab.kind.rawValue)", "tab")
            selectTab(tab.id)
            scheduleSave()
            return
        }
        NSSound.beep()
    }

    /// Everything a tab owns goes with it: its terminal, its runtime state, and the background session it's
    /// attached to.
    func dispose(_ tab: TabModel) {
        if let info = tabInfo(tab.id) {
            for ext in extensions { ext.tabClosing(info) }
        }
        if let job = tab.attachJobId { stopBackgroundJob(job) }
        terminals.terminate(tab.id)
        runtime[tab.id] = nil
        notifier?.clear(tab: tab.id)
        DebugLog.log("closed tab \(tab.id.uuidString.prefix(8)) kind=\(tab.kind.rawValue)", "tab")
    }

    /// A tab that hasn't launched its process yet in this run but will resume its agent's session when opened.
    func isSleeping(_ tab: TabModel) -> Bool {
        runtime[tab.id]?.started != true && (tab.agentSession != nil || tab.attachJobId != nil)
    }

    func closeActiveTab() {
        if let id = activeTab?.id { closeTab(id) }
    }

    func renameTab(_ id: UUID, to name: String) {
        guard let (g, t) = locate(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        groups[g].tabs[t].customTitle = trimmed.isEmpty ? nil : trimmed
        renamingTabID = nil
        scheduleSave()
        focusActiveTerminal()
    }

    func moveTab(_ id: UUID, before targetID: UUID?) {
        guard let (g, t) = locate(id), id != targetID else { return }
        if let targetID, locate(targetID)?.0 == g {
            // Within a group, the tab takes the target's place, as groups do.
            groups[g].tabs = Self.moving(id, onto: targetID, in: groups[g].tabs)
            scheduleSave()
            return
        }
        let tab = groups[g].tabs.remove(at: t)
        if let targetID, let (tg, tt) = locate(targetID) {
            groups[tg].tabs.insert(tab, at: tt)
            if tg != g { fixSelectionAfterMove(from: g, tabID: id) }
        } else {
            groups[g].tabs.append(tab)
        }
        scheduleSave()
    }

    func moveTab(_ id: UUID, toGroup groupID: UUID) {
        guard let (g, t) = locate(id), let tg = groups.firstIndex(where: { $0.id == groupID }), tg != g else { return }
        let tab = groups[g].tabs.remove(at: t)
        groups[tg].tabs.append(tab)
        fixSelectionAfterMove(from: g, tabID: id)
        scheduleSave()
    }

    private func fixSelectionAfterMove(from g: Int, tabID: UUID) {
        if groups[g].selectedTabID == tabID { groups[g].selectedTabID = groups[g].tabs.first?.id }
    }


    /// The side panel on Changes, for the active tab (⇧⌘D).
    func showChanges() {
        guard let tab = activeTab, tab.kind != .files, tab.kind != .command, let (g, t) = locate(tab.id) else {
            NSSound.beep()
            return
        }
        groups[g].tabs[t].panelHidden = false
        groups[g].tabs[t].panelTab = "changes"
        scheduleSave()
    }

    /// The active tab's folder (or the group's) in a Finder window (⇧⌘O).
    func openInFinder() {
        guard let dir = activeTab?.cwd ?? selectedGroup?.dir else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
    }

    /// A File Explorer tab moves up to its folder's parent, with the folder it came from selected.
    func explorerUp(_ id: UUID) {
        guard let folder = tab(id)?.cwd else { return }
        let url = URL(fileURLWithPath: folder)
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { NSSound.beep(); return }
        explorerOpen(id, folder: parent.path, selecting: url.path)
    }

    /// A File Explorer tab shows `folder` instead (right-click a folder → Open Here). A new folder gets a new
    /// tree: `TerminalRegistry.explorer(for:)`.
    func explorerOpen(_ id: UUID, folder: String, selecting: String? = nil) {
        guard let (g, t) = locate(id), groups[g].tabs[t].kind == .files else { return }
        groups[g].tabs[t].cwd = folder
        groups[g].tabs[t].explorerSelection = selecting
        scheduleSave()
    }

    func setExplorerSelection(_ id: UUID, _ path: String) {
        guard let (g, t) = locate(id), groups[g].tabs[t].explorerSelection != path else { return }
        groups[g].tabs[t].explorerSelection = path
        scheduleSave()
    }

    /// `path` relative to `folder` when it's inside it, else unchanged.
    static func path(_ path: String, relativeTo folder: String) -> String {
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// Types a file's path into the group's agent tab used most recently (Claude, Codex or another), without
    /// pressing Enter, and switches to it, so you can finish the sentence. The path is relative to that agent's
    /// folder when the file is inside it, else absolute, so a worktree tab never gets a path meaning another file.
    func sendPathToAgent(_ path: String, from id: UUID) {
        guard let (g, _) = locate(id) else { return }
        let agentTabs = groups[g].tabs.filter { runtime[$0.id]?.agentPresent == true }
        guard let target = agentTabs.max(by: { (lastFocusedAt[$0.id] ?? .distantPast) < (lastFocusedAt[$1.id] ?? .distantPast) }) else {
            let alert = NSAlert()
            alert.messageText = "No agent running in this group"
            alert.informativeText = "Start Claude or Codex in a tab of \(groups[g].name), then send the path again."
            alert.runModal()
            return
        }
        selectTab(target.id)
        let shown = Self.path(path, relativeTo: target.cwd)
        let quoted = shown.contains(" ") ? "\"\(shown)\"" : shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            // Still an agent tab? Never type a path into whatever replaced it.
            guard let self, self.runtime[target.id]?.agentPresent == true else { return }
            self.terminals.typeIntoTerminal(target.id, quoted + " ")
        }
    }
}
