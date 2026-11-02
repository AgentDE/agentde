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
