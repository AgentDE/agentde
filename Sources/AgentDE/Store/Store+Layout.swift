import AppKit

/// Several of a group's tabs on screen at once (`GroupModel.layout`). The selected tab is the active pane: the
/// tab strip, the side panel and the keys act on it. Choosing a tab that isn't showing puts it in the active pane.
extension Store {
    /// The group's split layout, without tabs that have gone; nil when it shows one tab.
    func layout(of group: GroupModel) -> PaneLayout? {
        group.layout?.pruned(to: Set(group.tabs.map(\.id)))
    }

    /// Splits the active pane (⌘D right, ⌥⌘D down), showing `tabID` in the new half, or else the tab used most
    /// recently that isn't showing yet. The new pane becomes active.
    func split(vertical: Bool, with tabID: UUID? = nil) {
        guard let group = selectedGroup, let g = groups.firstIndex(where: { $0.id == group.id }),
              let active = group.selectedTabID ?? group.tabs.first?.id else { return }
        let current = layout(of: group) ?? .tab(active)
        let showing = Set(current.tabs)
        let candidate = tabID.flatMap { id in showing.contains(id) ? nil : id }
            ?? group.tabs.filter { !showing.contains($0.id) }
                .max { (lastFocusedAt[$0.id] ?? .distantPast) < (lastFocusedAt[$1.id] ?? .distantPast) }?.id
        guard let other = candidate else {
            NSSound.beep()
            activityNote = "Every tab in \(group.name) is already showing: open another to split"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.activityNote?.hasPrefix("Every tab in") == true { self?.activityNote = nil }
            }
            return
        }
        groups[g].layout = current.splitting(active, with: other, vertical: vertical)
        selectTab(other)
        scheduleSave()
    }

    /// Takes a tab's pane out of the split (the tab stays open). With one pane left, the split ends.
    func removePane(_ id: UUID) {
        guard let (g, _) = locate(id), let current = layout(of: groups[g]) else { return }
        groups[g].layout = current.removing(id).flatMap { $0.tabs.count >= 2 ? $0 : nil }
        if groups[g].selectedTabID == id, let next = (groups[g].layout?.tabs ?? current.removing(id)?.tabs)?.first {
            selectTab(next)
        }
        scheduleSave()
    }

    /// Back to one tab: the active one.
    func unsplit() {
        guard let g = groups.firstIndex(where: { $0.id == selectedGroupID }), groups[g].layout != nil else { return }
        groups[g].layout = nil
        scheduleSave()
        focusActiveTerminal()
    }

    /// The next (or previous) pane becomes active (⌥⌘→, ⌥⌘←).
    func cyclePane(_ delta: Int) {
        guard let group = selectedGroup, let layout = layout(of: group), let active = group.selectedTabID,
              let index = layout.tabs.firstIndex(of: active) else { NSSound.beep(); return }
        let tabs = layout.tabs
        selectTab(tabs[(index + delta + tabs.count) % tabs.count])
    }

    func setSplitRatio(_ ratio: Double, at path: [Bool], in groupID: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }), let current = layout(of: groups[g]) else { return }
        groups[g].layout = current.settingRatio(ratio, at: path)
        scheduleSave()
    }

    /// Selecting a tab with a split on screen: a showing tab just becomes active; another one replaces the
    /// active pane's tab. Called by `selectTab` before it changes the selection.
    func placeInLayout(_ id: UUID, group g: Int) {
        guard let current = layout(of: groups[g]), !current.tabs.contains(id), let active = groups[g].selectedTabID,
              current.tabs.contains(active) else { return }
        groups[g].layout = current.replacing(active, with: id)
    }
}
