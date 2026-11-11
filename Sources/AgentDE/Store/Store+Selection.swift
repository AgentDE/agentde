import AppKit

/// Which group and tab are active, keyboard navigation between them, and jumping to tabs that need you.
extension Store {
    func selectGroup(_ id: UUID) {
        selectedGroupID = id
        defer { refreshActivePullRequest() }
        if let group = selectedGroup, group.selectedTabID == nil, let first = group.tabs.first {
            selectTab(first.id)
        }
        markSeenVisibleTabs()
        scheduleSave()
        focusActiveTerminal()
    }

    func selectTab(_ id: UUID, focus: Bool = true) {
        guard let (g, _) = locate(id) else { return }
        selectedGroupID = groups[g].id
        groups[g].selectedTabID = id
        lastFocusedAt[id] = Date()
        noteActivity(id)
        refreshActivePullRequest()
        markSeenVisibleTabs()
        scheduleSave()
        if focus { focusActiveTerminal() }
    }

    /// Called when a terminal gains keyboard focus.
    func terminalFocused(_ id: UUID) {
        guard let group = selectedGroup, group.tabs.contains(where: { $0.id == id }) else { return }
        lastFocusedAt[id] = Date()
        markSeen(id)
    }

    func cycleTab(_ delta: Int) {
        guard let group = selectedGroup, !group.tabs.isEmpty else { return }
        let current = group.tabs.firstIndex { $0.id == group.selectedTabID } ?? 0
        let next = (current + delta + group.tabs.count) % group.tabs.count
        selectTab(group.tabs[next].id)
    }

    func selectTab(number: Int) {
        guard let group = selectedGroup, !group.tabs.isEmpty else { return }
        let index = number == 9 ? group.tabs.count - 1 : min(number - 1, group.tabs.count - 1)
        selectTab(group.tabs[index].id)
    }

    func cycleGroup(_ delta: Int) {
        guard let index = selectedGroupIndex, !groups.isEmpty else { return }
        selectGroup(groups[(index + delta + groups.count) % groups.count].id)
    }

    /// Jumps to the next tab that wants attention: needs-you tabs first, then ones with an open question in
    /// their workstream (an extension's attention ring), then finished-but-unseen ones.
    func jumpToAttention() {
        let ordered = groups.flatMap { $0.tabs }
        guard !ordered.isEmpty else { NSSound.beep(); return }
        let start = ordered.firstIndex { $0.id == activeTab?.id } ?? -1
        let wants: [(TabModel) -> Bool] = [{ self.state($0.id) == .needsYou }, { self.wantsAttention($0) },
                                           { self.state($0.id) == .doneUnseen }]
        for wanted in wants {
            for offset in 1...max(ordered.count, 1) {
                let tab = ordered[(start + offset + ordered.count) % ordered.count]
                if wanted(tab) {
                    selectTab(tab.id)
                    NSSound(named: "Pop")?.play()
                    return
                }
            }
        }
        NSSound.beep()
    }
}

extension Store {
    func noteActivity(_ id: UUID) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].lastActiveAt = Date()
        scheduleSave()
    }

    /// Whether `date` is today. A day starts at 4 AM, so late-night work still counts as the same day.
    static func isToday(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let shift: TimeInterval = -4 * 3600
        return calendar.isDate(date.addingTimeInterval(shift), inSameDayAs: now.addingTimeInterval(shift))
    }

    /// Tabs the sidebar's filter keeps: anything with a status or an open question, the tab on screen, and any
    /// tab active today (from its own record, or its session's transcript for tabs from before there was one).
    func tabsActiveToday() -> Set<UUID> {
        let sessions = Dictionary((recentSessions + (olderSessions ?? [])).map { ($0.sessionId, $0.lastActive) }) { a, b in max(a, b) }
        var ids = Set<UUID>()
        for tab in groups.flatMap(\.tabs) {
            let dates = [tab.lastActiveAt, agentSession(of: tab).flatMap { sessions[$0] }].compactMap { $0 }
            if state(tab.id) != .none || wantsAttention(tab) || tab.id == activeTab?.id || dates.contains(where: { Self.isToday($0) }) {
                ids.insert(tab.id)
            }
        }
        return ids
    }
}

extension Store {
    /// Whether every word of `query` appears in any of `fields`, ignoring case (the sidebar search's name match).
    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = fields.joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// ⌘K: shows the sidebar and puts the cursor in its search box.
    func focusSidebarSearch() {
        sidebarVisible = true
        sidebarSearchFocus += 1
    }
}
