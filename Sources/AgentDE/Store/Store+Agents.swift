import AppKit

/// Agent workflows: startup commands, pull requests and attention state.
extension Store {
    /// The startup command for a tab: its group's override, else the app-wide default.
    func startupCommand(for tab: TabModel) -> String? {
        let group = locate(tab.id).map { groups[$0.group] }
        return group?.startupCommand ?? settings.startupCommand
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
