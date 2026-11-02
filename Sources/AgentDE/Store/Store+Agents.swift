import AppKit

/// Agent workflows: startup commands, forks and background sessions, background agents, and attention state.
extension Store {
    /// The startup command for a tab: its group's override, else the app-wide default.
    func startupCommand(for tab: TabModel) -> String? {
        let group = locate(tab.id).map { groups[$0.group] }
        return group?.startupCommand ?? settings.startupCommand
    }

    /// Forks a tab's Claude conversation into a new tab beside it (`claude --resume <id> --fork-session`).
    func forkTab(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, let (g, t) = locate(id) else { return }
        let source = groups[g].tabs[t]
        guard let sessionId = source.claudeSessionId else {
            let alert = NSAlert()
            alert.messageText = "No Claude session to fork"
            alert.informativeText = "Start Claude in this tab first. Forking copies its conversation into a new tab."
            alert.runModal()
            return
        }
        var fork = TabModel(kind: .claude, cwd: source.cwd)
        fork.claudeSessionId = sessionId
        fork.forkOnStart = true
        groups[g].tabs.insert(fork, at: t + 1)
        selectTab(fork.id)
        scheduleSave()
    }

    /// `notYet`: not a session to open as things stand (a spare, or no name yet); the monitor asks again each poll.
    enum BackgroundAdoption { case adopted, ignored, retryLater, notYet }

    /// Which background sessions get a tab: forks, and sessions with a name of their own. Not the daemon's spares,
    /// which are named after their job id until a resume or `--bg` claims them.
    static func opensAsTab(_ entry: ClaudeSessionEntry, isFork: () -> Bool) -> Bool {
        if entry.spare == true { return false }
        if let name = entry.name, !name.isEmpty, name != entry.jobId { return true }
        return isFork()
    }

    /// Where a new tab for a background session in `cwd` goes: after the most recently focused tab in that
    /// folder, else at the end of the group whose folder contains it. Nil when no group covers the folder.
    static func placement(forBackgroundIn cwd: String, groups: [GroupModel],
                          lastFocusedAt: [UUID: Date]) -> (group: Int, index: Int)? {
        var best: (group: Int, index: Int, at: Date)?
        for (g, group) in groups.enumerated() {
            for (t, tab) in group.tabs.enumerated() where tab.cwd == cwd {
                let at = lastFocusedAt[tab.id] ?? .distantPast
                if best == nil || at > best!.at { best = (g, t + 1, at) }
            }
        }
        if let best { return (best.group, best.index) }
        let folder = { (dir: String) in dir.hasSuffix("/") ? dir : dir + "/" }
        let owners = groups.indices.filter { cwd == groups[$0].dir || cwd.hasPrefix(folder(groups[$0].dir)) }
        guard let g = owners.max(by: { groups[$0].dir.count < groups[$1].dir.count }) else { return nil }
        return (g, groups[g].tabs.count)
    }

    /// Opens a new background Claude session (from `/fork`, or `claude --bg` run anywhere) as an ordinary tab
    /// that attaches to it, beside the last tab used in its folder (see `opensAsTab` for which ones). A background-mode tab in that folder that
    /// hasn't reported its own job yet makes this wait (`retryLater`), so its job isn't opened twice.
    func adoptBackgroundSession(_ entry: ClaudeSessionEntry) -> BackgroundAdoption {
        guard let jobId = SafeID.job(entry.jobId), let cwd = entry.cwd,
              !groups.contains(where: { $0.tabs.contains { $0.attachJobId == jobId || $0.claudeSessionId == entry.sessionId } })
        else { return .ignored }
        guard Store.opensAsTab(entry, isFork: { Store.forkParent(job: jobId) != nil }) else { return .notYet }
        pendingBackgroundLaunches = pendingBackgroundLaunches.filter { Date().timeIntervalSince($0.value) < 60 }
        if pendingBackgroundLaunches.keys.contains(where: { tab($0)?.cwd == cwd }) { return .retryLater }
        guard let (g, index) = Store.placement(forBackgroundIn: cwd, groups: groups, lastFocusedAt: lastFocusedAt)
        else { return .ignored }
        DebugLog.log("opened background job \(jobId) (\(entry.name ?? "unnamed")) in a new tab in \(groups[g].name)", "agent")
        var tab = TabModel(kind: .claude, cwd: cwd)
        tab.attachJobId = jobId
        tab.claudeSessionId = entry.sessionId
        tab.lastAgentName = entry.name
        groups[g].tabs.insert(tab, at: index)
        var rt = TabRuntime()
        rt.agentName = entry.name
        rt.sparkleToken = 1
        rt.sparkleAt = Date()
        runtime[tab.id] = rt
        if let info = tabInfo(tab.id) {
            let parent = Store.forkParent(job: jobId)
            for ext in extensions { ext.backgroundSessionOpened(info, session: entry.sessionId, forkParent: parent) }
        }
        NSSound(named: "Pop")?.play()
        scheduleSave()
        return .adopted
    }

    /// Live background sessions in Claude's registry, as session id → job id.
    static func liveBackgroundJobs(in sessionsDir: URL) -> [String: String] {
        var jobs: [String: String] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(ClaudeSessionEntry.self, from: data),
                  entry.kind == "bg", let session = entry.sessionId, let job = SafeID.job(entry.jobId),
                  kill(entry.pid, 0) == 0 else { continue }
            jobs[session] = job
        }
        return jobs
    }

    /// A restored Claude tab whose session is running as a background job attaches to that job rather than
    /// resuming a second live copy of the same conversation.
    func attachToLiveBackgroundJobs(_ jobsBySession: [String: String]) {
        for g in groups.indices {
            for t in groups[g].tabs.indices {
                let tab = groups[g].tabs[t]
                guard tab.kind == .claude, tab.attachJobId == nil, let session = tab.claudeSessionId,
                      let job = jobsBySession[session] else { continue }
                DebugLog.log("tab \(tab.id.uuidString.prefix(8)) attaches to background job \(job) instead of resuming its session", "agent")
                groups[g].tabs[t].attachJobId = job
                groups[g].tabs[t].forkOnStart = nil
            }
        }
    }

    func editStartupCommand(group id: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Startup command for \(groups[g].name)"
        alert.informativeText = "Runs in each new tab of this group before Claude or Codex starts. "
            + "Leave empty to use the default from Settings (\(settings.startupCommand.isEmpty ? "none" : settings.startupCommand)). "
            + "Enter : to run nothing."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "conda activate myenv"
        field.stringValue = groups[g].startupCommand ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[g].startupCommand = value.isEmpty ? nil : value
        scheduleSave()
    }

    func refreshActivePullRequest(force: Bool = false) {
        guard settings.showPullRequests, let dir = activeTab?.cwd ?? selectedGroup?.dir else { return }
        pullRequestMonitor.refresh(dir: dir, force: force)
    }

    // MARK: Background agents

    /// A background-mode tab reported its job id; from now on it re-attaches instead of starting anew.
    /// Returns whether the receipt was this instance's to consume: the tab exists here, and the job id is
    /// now saved to disk (immediately, not debounced, so a crash can't lose the attachment).
    @discardableResult
    func recordAttachedJob(tab id: UUID, jobId: String) -> Bool {
        guard let (g, t) = locate(id) else {
            // Another AgentDE instance's tab, or a tab closed since; stale receipts are cleaned up after a day.
            return false
        }
        if groups[g].tabs[t].attachJobId != jobId {
            groups[g].tabs[t].attachJobId = jobId
            groups[g].tabs[t].forkOnStart = nil
            DebugLog.log("tab \(id.uuidString.prefix(8)) attached to background job \(jobId)", "agent")
        }
        pendingBackgroundLaunches[id] = nil
        save()
        return true
    }

    /// Stops a background session (`claude stop`): its tab closed, so the agent ends too. The conversation is
    /// kept, so it can be resumed from the group's recent sessions. A failure only goes to the log.
    func stopBackgroundJob(_ job: String) {
        guard let job = SafeID.job(job) else { return }
        // Interactive login shell, like the tabs, so `claude` is on PATH even when .zshrc puts it there.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lic", "claude stop \(job)"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        task.terminationHandler = { finished in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let last = text.split(separator: "\n").last.map(String.init) ?? ""
            DebugLog.log("claude stop \(job) exit \(finished.terminationStatus): \(last.prefix(200))", "agent")
        }
        do { try task.run() } catch { DebugLog.log("couldn't run claude stop: \(error)", "agent") }
    }


    // MARK: Agent state

    func markSeen(_ id: UUID) {
        notifier?.clear(tab: id)
        if runtime[id]?.state == .doneUnseen { runtime[id]?.state = .none }
        if runtime[id]?.state == .needsYou, tab(id)?.kind == .shell || runtime[id]?.agentPresent != true {
            runtime[id]?.state = .none
        }
        updateDockBadge()
    }

    func markSeenVisibleTabs() {
        guard NSApp.isActive, let group = selectedGroup else { return }
        if let id = group.selectedTabID { markSeen(id) }
    }

    func bell(_ id: UUID) {
        guard !(NSApp.isActive && isVisible(id)) else { return }
        if runtime[id]?.state != .working { runtime[id, default: TabRuntime()].state = .needsYou }
        updateDockBadge()
    }

    func updateDockBadge() {
        let count = runtime.values.filter { $0.state == .needsYou }.count
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }
}
