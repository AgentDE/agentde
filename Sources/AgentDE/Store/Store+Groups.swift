import AppKit

/// Creating, renaming, recoloring, collapsing, reordering and deleting groups.
extension Store {
    func newGroup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create group"
        panel.message = "Choose the folder this group's tabs open in"
        panel.directoryURL = URL(fileURLWithPath: selectedGroup?.dir ?? NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let used = Set(groups.map { $0.colorIndex % 8 })
        let color = (0..<8).first { !used.contains($0) } ?? groups.count % 8
        let group = GroupModel(name: url.lastPathComponent, colorIndex: color, dir: url.path)
        groups.append(group)
        selectedGroupID = group.id
        newTab(kind: settings.defaultTabKind, in: group.id)
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { groups[g].name = trimmed }
        renamingGroupID = nil
        scheduleSave()
        focusActiveTerminal()
    }

    /// Points a group at another folder (the repository moved or was renamed): its tabs inside the old folder
    /// move along, to the same place inside the new one. Tabs elsewhere (another repository's worktrees, say)
    /// stay, and the confirmation says how many move. Tabs restart in the new place next time they start.
    func changeGroupFolder(_ id: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        let old = groups[g].dir
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder for \(groups[g].name) (it was \(old.abbreviatingHome))"
        panel.directoryURL = URL(fileURLWithPath: old).deletingLastPathComponent()
        guard panel.runModal() == .OK, let new = panel.url?.path, new != old,
              let g = groups.firstIndex(where: { $0.id == id }) else { return }
        // A running terminal stays where its process is: moving only its folder in AgentDE would point Files,
        // Changes and Send Path at a different repository than the agent works in. Those tabs keep their
        // folder; close and reopen them (⌥⇧⌘T) to start them in the new place.
        // A tab already waiting to move (an earlier Change Folder) is rebased from where it's going.
        let inside = groups[g].tabs.filter { Self.moved($0.movedTo ?? $0.cwd, from: old, to: new) != nil }
        let running = inside.filter { runtime[$0.id]?.started == true }
        let detail = "\(inside.count - running.count) of its \(groups[g].tabs.count) tabs move with it."
            + (running.isEmpty ? "" : " \(running.count) running \(running.count == 1 ? "tab stays" : "tabs stay") in the old folder until closed and reopened.")
        guard confirm("Move \(groups[g].name) to \(new.abbreviatingHome)?", detail: detail, button: "Move"),
              let g = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[g].dir = new
        for t in groups[g].tabs.indices {
            guard let moved = Self.moved(groups[g].tabs[t].movedTo ?? groups[g].tabs[t].cwd, from: old, to: new) else { continue }
            if runtime[groups[g].tabs[t].id]?.started == true {
                groups[g].tabs[t].movedTo = moved   // applied when it's reopened
            } else {
                groups[g].tabs[t].cwd = moved
                groups[g].tabs[t].movedTo = nil
            }
        }
        let moving = inside.count - running.count
        DebugLog.log("group \(groups[g].name) moved from \(old.abbreviatingHome) to \(new.abbreviatingHome), \(moving) tabs along", "tab")
        scheduleSave()
    }

    /// `path` inside `old`, rebased onto `new`; nil when it isn't inside `old`.
    static func moved(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        let base = old.hasSuffix("/") ? old : old + "/"
        guard path.hasPrefix(base) else { return nil }
        return (new.hasSuffix("/") ? new : new + "/") + path.dropFirst(base.count)
    }

    func setGroupColor(_ id: UUID, _ index: Int) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[g].colorIndex = index
        scheduleSave()
    }

    func toggleRecentHidden(_ id: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[g].hideRecent = !(groups[g].hideRecent ?? false)
        scheduleSave()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[g].collapsed = !(groups[g].collapsed ?? false)
        scheduleSave()
    }

    /// Collapses every group, or expands them all if they're all collapsed already.
    func toggleAllCollapsed() {
        let collapse = groups.contains { !($0.collapsed ?? false) }
        for g in groups.indices { groups[g].collapsed = collapse }
        scheduleSave()
    }

    func deleteGroup(_ id: UUID) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        let busy = groups[g].tabs.filter { state($0.id) == .working }.count
        let detail = busy > 0 ? "\(busy) agent(s) in it are still working." : "Its \(groups[g].tabs.count) tab(s) will close."
        guard confirm("Delete group \(groups[g].name)?", detail: detail, button: "Delete"),
              let g = groups.firstIndex(where: { $0.id == id }) else { return }
        for tab in groups[g].tabs { dispose(tab) }
        groups.remove(at: g)
        if selectedGroupID == id { selectedGroupID = groups.first?.id }
        scheduleSave()
    }

    /// A group dropped on another takes its place: dragged down, it lands below it; dragged up, above.
    func moveGroup(_ id: UUID, onto targetID: UUID) {
        let moved = Self.moving(id, onto: targetID, in: groups)
        if moved.map(\.id) != groups.map(\.id) { groups = moved; scheduleSave() }
    }

    static func moving<T: Identifiable>(_ id: T.ID, onto targetID: T.ID, in items: [T]) -> [T] {
        guard let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == targetID }) else { return items }
        var items = items
        items.insert(items.remove(at: from), at: to)
        return items
    }
}
