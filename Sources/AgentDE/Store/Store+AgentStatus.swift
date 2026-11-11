import AppKit

/// Turns what the agent monitor sees in Claude's registry into tab states, names and notifications.
extension Store {
    /// Banners for state changes you can't see: needs-you while the tab is hidden, or a finish you missed.
    func notifyTransition(_ tabID: UUID, from old: AgentState, to rt: TabRuntime) {
        if old != rt.state {
            if rt.state == .working || rt.state == .needsYou { noteActivity(tabID) }
            DebugLog.log("tab \(tabID.uuidString.prefix(8)) \(old) -> \(rt.state)" + (rt.waitingFor.map { " (\($0))" } ?? ""), "agent")
            // An agent that just went idle can take an ask's overdue default.
            if rt.state == .none || rt.state == .doneUnseen {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let info = self.tabInfo(tabID) else { return }
                    for ext in self.extensions { ext.agentWentIdle(info) }
                }
            }
        }
        guard let notifier, let tab = tab(tabID), let (g, _) = locate(tabID) else { return }
        let looking = NSApp.isActive && isVisible(tabID)
        if rt.state == .needsYou, old != .needsYou, !looking {
            notifier.notify(.needsYou, tab: tab, title: title(for: tab), groupName: groups[g].name, waitingFor: rt.waitingFor)
        } else if rt.state == .doneUnseen, old == .working {
            notifier.notify(.done, tab: tab, title: title(for: tab), groupName: groups[g].name, waitingFor: nil)
        }
    }

    func applyClaudeSessions(_ matches: [UUID: ClaudeSessionEntry], jobs: [String: ClaudeSessionEntry], trackedTabs: Set<UUID>) {
        var dirty = false
        var matches = matches
        var tracked = trackedTabs
        // Tabs attached to background sessions get status from the session itself, which runs outside the tab.
        // Every attached tab is checked, started or not, so a job that ended doesn't leave a stale state behind.
        var attached: [UUID: ClaudeSessionEntry] = [:]
        for group in groups {
            for tab in group.tabs {
                if let job = tab.attachJobId {
                    tracked.insert(tab.id)
                    if let entry = jobs[job] { attached[tab.id] = entry }
                }
            }
        }
        for tabID in tracked.union(attached.keys) {
            var rt = runtime[tabID] ?? TabRuntime()
            let before = rt
            if let entry = attached[tabID] ?? matches[tabID] {
                rt.agentPresent = true
                rt.missedPolls = 0
                rt.agentName = entry.name
                rt.agentPid = entry.pid
                rt.claudeVersion = entry.version
                switch entry.status {
                case "busy", "shell":
                    if rt.state != .working { rt.busySince = Date() }
                    rt.state = .working
                case "waiting":
                    rt.state = .needsYou
                    rt.waitingFor = entry.waitingFor
                default:
                    if rt.state == .working {
                        let worked = rt.busySince.map { Date().timeIntervalSince($0) } ?? 0
                        rt.state = (NSApp.isActive && isVisible(tabID)) ? .none : .doneUnseen
                        if settings.sparkles, animations, worked >= settings.sparkleAfterSeconds {
                            rt.sparkleToken += 1
                            rt.sparkleAt = Date()
                        }
                    } else if rt.state == .needsYou {
                        rt.state = .none
                    }
                    rt.busySince = nil
                }
                if entry.fromHook == true, let sessionId = entry.sessionId, let (g, t) = locate(tabID) {
                    // Another agent's own report: a Codex tab keeps its thread to resume; nothing else changes.
                    if groups[g].tabs[t].kind == .codex, groups[g].tabs[t].codexSessionId != sessionId {
                        groups[g].tabs[t].codexSessionId = sessionId
                        dirty = true
                    }
                } else if let sessionId = entry.sessionId, let (g, t) = locate(tabID) {
                    var tab = groups[g].tabs[t]
                    if let name = entry.name, !name.isEmpty, tab.lastAgentName != name { tab.lastAgentName = name; dirty = true }
                    if tab.claudeSessionId != sessionId {
                        tab.claudeSessionId = sessionId
                        tab.forkOnStart = nil
                        dirty = true
                    }
                    // Claude started in a shell tab (`claude --resume …`, say): it becomes a Claude tab, named and
                    // resumed like one from now on.
                    if tab.kind == .shell { tab.kind = .claude; dirty = true }
                    if let cwd = entry.cwd, tab.cwd != cwd, FileManager.default.fileExists(atPath: cwd) {
                        tab.cwd = cwd; dirty = true
                    }
                    if groups[g].tabs[t] != tab { groups[g].tabs[t] = tab }
                }
            } else if rt.agentPresent || rt.state == .working || rt.state == .needsYou {
                // Gone for three polls in a row (not one failed read): Claude exited, or the job ended.
                rt.missedPolls += 1
                if rt.missedPolls >= 3 {
                    rt.agentPresent = false
                    rt.agentName = nil
                    rt.agentPid = nil
                    rt.claudeVersion = nil
                    rt.missedPolls = 0
                    if rt.state == .working || rt.state == .needsYou { rt.state = .none }
                }
            }
            if rt.state != .needsYou { rt.waitingFor = nil }
            if rt.state != before.state || rt.agentName != before.agentName || rt.sparkleToken != before.sparkleToken
                || rt.waitingFor != before.waitingFor || rt.agentPresent != before.agentPresent || rt.missedPolls != before.missedPolls
                || rt.agentPid != before.agentPid || rt.claudeVersion != before.claudeVersion {
                runtime[tabID] = rt
                notifyTransition(tabID, from: before.state, to: rt)
            }
        }
        if dirty {
            scheduleSave()
            agentSessionsChanged()
        }
        updateDockBadge()
    }
}
