import AppKit
import AgentDEKit

extension Store {
    /// Asks for a branch name and an agent, makes a git worktree on that new branch (from the remote's
    /// default branch) beside the group's repository, and opens the agent there in a tab named after it.
    /// Worktrees are never removed for you: the agent cleans up after itself.
    func newWorktreeTab(in groupID: UUID? = nil) {
        guard let group = groupID.flatMap({ id in groups.first { $0.id == id } }) ?? selectedGroup else { return }
        guard let root = Worktrees.repoRoot(of: group.dir) else {
            showProblem("\(group.name) isn't in a git repository", "\(group.dir.abbreviatingHome) has no repository to make a worktree from.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "New tab in a worktree"
        alert.informativeText = "Makes a branch of this name from \(Worktrees.baseBranch(repoRoot: root) ?? "what's checked out"), "
            + "checks it out in \(Worktrees.path(repoRoot: root, name: "…").abbreviatingHome), and starts the agent there."
        let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        field.placeholderString = "fix-login"
        let agent = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
        agent.addItems(withTitles: [TabKind.claude.label, TabKind.codex.label])
        if settings.defaultTabKind == .codex { agent.selectItem(at: 1) }
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        accessory.addSubview(field)
        accessory.addSubview(agent)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = Worktrees.validName(field.stringValue) else {
            showProblem("“\(field.stringValue)” can't be a branch name",
                        "Use letters, digits, dots, dashes and underscores, starting with a letter or digit.")
            return
        }
        let kind: TabKind = agent.indexOfSelectedItem == 1 ? .codex : .claude
        let groupID = group.id
        // Fetching and checking out can take a while: say so, so the click doesn't look ignored.
        activityNote = "Making worktree \(name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Worktrees.add(repoRoot: root, name: name)
            DispatchQueue.main.async { [self] in
                activityNote = nil
                switch result {
                case .failure(let error): showProblem("Couldn't make the worktree for \(name)", error.message)
                case .success(let base):
                    DebugLog.log("new worktree \(name) from \(base) for group \(group.name)", "tab")
                    _ = openTab(kind: kind, in: groupID, folder: Worktrees.path(repoRoot: root, name: name), title: name)
                    if base.hasSuffix("(last fetched)") {
                        // Offline, say: the branch starts from what was fetched before, which may be behind.
                        activityNote = "\(name) started from \(base): the fetch failed"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            if self?.activityNote?.hasPrefix(name + " started") == true { self?.activityNote = nil }
                        }
                    }
                }
            }
        }
    }

    /// Keeps the PR status of tabs in their own folder (worktrees, say) current, for the sidebar. The
    /// monitor asks `gh` at most once a minute per folder and branch.
    func refreshTabPullRequests() {
        guard settings.showPullRequests else { return }
        for group in groups {
            for tab in group.tabs where onOwnBranch(tab, in: group) { pullRequestMonitor.refresh(dir: tab.cwd) }
        }
    }

    /// A terminal tab on another branch than its group's folder (a worktree tab): its sidebar row shows its PR.
    func onOwnBranch(_ tab: TabModel, in group: GroupModel) -> Bool {
        guard tab.kind != .files, tab.kind != .command, tab.cwd != group.dir, let branch = GitInfo.branch(at: tab.cwd) else { return false }
        return branch != GitInfo.branch(at: group.dir)
    }
}
