import AppKit

/// Opening, closing, renaming and moving tabs; the browser pane; editor and diff actions.
extension Store {
    @discardableResult
    func newTab(kind: TabKind, in groupID: UUID? = nil, command: String? = nil, transient: Bool = false,
                sessionId: String? = nil, cwd: String? = nil, attachJobId: String? = nil) -> UUID? {
        guard let g = groups.firstIndex(where: { $0.id == (groupID ?? selectedGroupID) }) else { return nil }
        let cwd = cwd ?? (groupID == nil ? activeTab?.cwd : nil) ?? groups[g].dir
        var tab = TabModel(kind: kind, cwd: cwd, command: command, transient: transient ? true : nil)
        tab.claudeSessionId = sessionId
        tab.attachJobId = attachJobId
        DebugLog.log("new tab \(tab.id.uuidString.prefix(8)) kind=\(kind.rawValue) group=\(groups[g].name)"
                     + (sessionId.map { " session=\($0.prefix(8))" } ?? "") + (attachJobId.map { " attach=\($0)" } ?? ""), "tab")
        let insertAt = (groups[g].tabs.firstIndex { $0.id == groups[g].selectedTabID }).map { $0 + 1 } ?? groups[g].tabs.count
        groups[g].tabs.insert(tab, at: insertAt)
        selectTab(tab.id)
        return tab.id
    }

    /// A new tab running an added agent (`AgentDefinition`).
    @discardableResult
    func newAgentTab(_ agent: AgentDefinition, in groupID: UUID? = nil) -> UUID? {
        guard let id = newTab(kind: .agent, in: groupID), let (g, t) = locate(id) else { return nil }
        groups[g].tabs[t].agentID = agent.id
        DebugLog.log("tab \(id.uuidString.prefix(8)) runs agent \(agent.id)", "tab")
        return id
    }

    /// Closes a tab. A background agent's tab stops its agent too, unless `keepAgent` (right-click → Close,
    /// keep agent running).
    func closeTab(_ id: UUID, confirmIfBusy: Bool = true, keepAgent: Bool = false) {
        guard let tab = tab(id) else { return }
        if confirmIfBusy, state(id) == .working, !keepAgent,
           !confirm("Stop a working agent?", detail: "\(title(for: tab)) is still running a turn, and closing stops it. "
                    + "The conversation is kept, so you can resume it from Recent.", button: "Close & Stop Agent") {
            return
        }
        // The alert ran the event loop, so the tab may have moved or gone: look it up again.
        guard let (g, t) = locate(id) else { return }
        rememberClosed(groups[g].tabs[t], group: groups[g].id, at: t, keptAgent: keepAgent && groups[g].tabs[t].attachJobId != nil)
        dispose(groups[g].tabs[t], keepAgent: keepAgent)
        let wasSelected = groups[g].selectedTabID == id
        groups[g].tabs.remove(at: t)
        if wasSelected {
            if !groups[g].tabs.isEmpty {
                groups[g].selectedTabID = groups[g].tabs[min(t, groups[g].tabs.count - 1)].id
            } else {
                groups[g].selectedTabID = nil
            }
        }
        scheduleSave()
        focusActiveTerminal()
    }

    /// The last few closed tabs, newest last, for Reopen Closed Tab (this run only).
    struct ClosedTab { var tab: TabModel; var group: UUID; var index: Int; var keptAgent = false }

    private func rememberClosed(_ tab: TabModel, group: UUID, at index: Int, keptAgent: Bool) {
        guard tab.transient != true, tab.kind != .command else { return }
        closedTabs.append(ClosedTab(tab: tab, group: group, index: index, keptAgent: keptAgent))
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    }

    /// Brings back the last closed tab where it was: its folder (a worktree too), its session (resumed, since
    /// closing stopped the agent), title, viewer and panel. Its terminal starts fresh.
    func reopenClosedTab(waited: Int = 0) {
        // Its background job is still being stopped, or still listed as running: wait (up to 10 s), so the
        // session isn't attached to a job that's exiting, nor resumed beside one that's still alive.
        if let last = closedTabs.last, !last.keptAgent, let job = last.tab.attachJobId, waited < 50,
           stoppingJobs.contains(job) || (liveBackgroundJobs.values.contains(job) && !failedStops.contains(job)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reopenClosedTab(waited: waited + 1) }
            return
        }
        while let closed = closedTabs.popLast() {
            guard let g = groups.firstIndex(where: { $0.id == closed.group }) ?? groups.indices.first else { continue }
            var tab = closed.tab
            tab.id = UUID()
            tab.forkOnStart = nil
            // A job kept running (Close, Keep Agent Running) is attached again. A stopped one resumes its session,
            // unless that session is live in the background anyway (stopping can lag), then it's attached.
            if !closed.keptAgent {
                let original = closed.tab.attachJobId
                if let original, liveBackgroundJobs.values.contains(original) {
                    // Its stop failed or is still going: attach to it rather than start a second copy.
                    tab.attachJobId = original
                    DebugLog.log("reopen: background job \(original) is still running; attaching to it", "tab")
                } else {
                    tab.attachJobId = tab.claudeSessionId.flatMap { liveBackgroundJobs[$0] }.flatMap { stoppingJobs.contains($0) ? nil : $0 }
                }
            }
            // A pending folder move applies when the agent starts fresh here, not when it reattaches to one
            // still running in the old folder.
            if tab.attachJobId == nil, let moved = tab.movedTo { tab.cwd = moved; tab.movedTo = nil }
            if tab.kind == .shell, tab.claudeSessionId == nil { tab.lastAgentName = nil }
            groups[g].tabs.insert(tab, at: min(closed.index, groups[g].tabs.count))
            DebugLog.log("reopened closed tab as \(tab.id.uuidString.prefix(8)) kind=\(tab.kind.rawValue)", "tab")
            selectTab(tab.id)
            scheduleSave()
            return
        }
        NSSound.beep()
    }

    /// Everything a tab owns goes with it: its terminal, its browser and its runtime state, and its background
    /// agent. With `keepAgent` the background agent keeps running and stays in its workstream, so its workstream
    /// tools keep working.
    func dispose(_ tab: TabModel, keepAgent: Bool = false) {
        if let info = tabInfo(tab.id) {
            for ext in extensions { ext.tabClosing(info, keepAgent: keepAgent && tab.attachJobId != nil) }
        }
        if !keepAgent, let job = tab.attachJobId { stopBackgroundJob(job) }
        terminals.terminate(tab.id)
        runtime[tab.id] = nil
        pendingBackgroundLaunches[tab.id] = nil
        notifier?.clear(tab: tab.id)
        DebugLog.log("closed tab \(tab.id.uuidString.prefix(8)) kind=\(tab.kind.rawValue)", "tab")
    }

    /// A tab that hasn't launched its process yet in this run but will resume a Claude session when opened.
    func isSleeping(_ tab: TabModel) -> Bool {
        runtime[tab.id]?.started != true && (tab.claudeSessionId != nil || tab.attachJobId != nil || tab.codexSessionId != nil)
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


    // MARK: Browser

    func toggleBrowser(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, let (g, t) = locate(id) else { return }
        let showing = groups[g].tabs[t].showBrowser ?? false
        groups[g].tabs[t].showBrowser = !showing
        scheduleSave()
    }

    func setBrowserURL(_ id: UUID, _ url: String) {
        guard let (g, t) = locate(id), groups[g].tabs[t].browserURL != url else { return }
        groups[g].tabs[t].browserURL = url
        scheduleSave()
    }

    func showDiff() {
        guard let tab = activeTab else { return }
        let dir = tab.cwd.replacingOccurrences(of: "'", with: "'\\''")
        let command = """
        cd '\(dir)' && { git -c color.ui=always status -sb; echo; git -c color.ui=always diff HEAD --stat; echo; \
        git -c color.ui=always diff HEAD; } 2>&1 | less -R
        """
        newTab(kind: .command, command: command, transient: true)
    }

    func openInEditor() {
        guard let dir = activeTab?.cwd ?? selectedGroup?.dir else { return }
        openInCursor(dir)
    }

    func openInCursor(_ path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Cursor", path]
        try? task.run()
    }

    func setExplorerSelection(_ id: UUID, _ path: String) {
        guard let (g, t) = locate(id), groups[g].tabs[t].explorerSelection != path else { return }
        groups[g].tabs[t].explorerSelection = path
        scheduleSave()
    }

    /// Shows a local file (e.g. an HTML report) in the tab's browser pane.
    func openInBrowserPane(_ id: UUID, _ url: URL) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].browserURL = url.absoluteString
        groups[g].tabs[t].showBrowser = true
        terminals.browsers.webView(for: id).loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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
