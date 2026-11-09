import SwiftUI

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Room for the window's traffic lights.
                Spacer().frame(width: 66)
                Text(AppBrand.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                IconButton(symbol: "sidebar.left", help: "Hide sidebar (⌘0)") { store.sidebarVisible = false }
            }
            .frame(height: 46)
            .padding(.horizontal, 10)

            Button { store.paletteOpen = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                    Text("Jump to…").font(.system(size: 12.5))
                    Spacer()
                    Text("⌘K").font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            HStack {
                Text("Groups").font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.muted)
                Spacer()
                Button { store.newGroup() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .hint("New group (⌘⇧N)")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(store.groups) { group in
                        GroupRow(group: group)
                        if !(group.collapsed ?? false) {
                            ForEach(group.tabs) { tab in SidebarTabRow(group: group, tab: tab) }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            if store.settings.showRecentSessions {
                                RecentSessionsList(group: group)
                            }
                            Spacer().frame(height: 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            if let footer = store.extensions.lazy.compactMap({ $0.sidebarFooter() }).first {
                footer
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            SidebarFooter()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct GroupRow: View {
    let group: GroupModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        let selected = group.id == store.selectedGroupID
        let states = group.tabs.map { store.state($0.id) }
        let collapsed = group.collapsed ?? false
        HStack(spacing: 7) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if NSEvent.modifierFlags.contains(.option) { store.toggleAllCollapsed() } else { store.toggleCollapsed(group.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.muted)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hint(collapsed ? "Expand (⌥-click: all groups)" : "Collapse (⌥-click: all groups)")
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: store.groupColor(group)))
                .frame(width: 10, height: 10)
            if store.renamingGroupID == group.id {
                RenameField(initial: group.name) { store.renameGroup(group.id, to: $0) }
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text(group.name)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? theme.text : theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if collapsed {
                GroupSummary(states: states, count: group.tabs.count)
            }
        }
        .padding(.leading, 2).padding(.trailing, 8)
        .frame(height: 30)
        // Open, its selected tab's row carries the highlight, so the two don't stack.
        .background(RoundedRectangle(cornerRadius: 7).fill(selected && (collapsed || group.tabs.isEmpty) ? theme.selected : hovering ? theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: store.groupColor(group)), lineWidth: dropTarget ? 1.5 : 0))
        .activeOutline(selected && (collapsed || group.tabs.isEmpty) && !dropTarget, radius: 7, dashed: true)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.renamingGroupID = group.id }
        .onTapGesture { store.selectGroup(group.id) }
        .draggable("group:\(group.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                if item.hasPrefix("tab:"), let id = UUID(uuidString: String(item.dropFirst(4))) {
                    store.moveTab(id, toGroup: group.id)
                } else if item.hasPrefix("group:"), let id = UUID(uuidString: String(item.dropFirst(6))) {
                    store.moveGroup(id, onto: group.id)
                }
            }
            return true
        } isTargeted: { dropTarget = $0 }
        .contextMenu {
            // The same choices as the tab strip's +.
            Menu("New") {
                ForEach([TabKind.claude, .codex, .shell, .files], id: \.self) { kind in
                    Button { store.newTab(kind: kind, in: group.id) } label: {
                        Label(kind == .files ? "File Explorer" : kind.label, systemImage: kind.symbol)
                    }
                }
                Button { store.newWorktreeTab(in: group.id) } label: { Label("Tab in Worktree…", systemImage: "arrow.triangle.branch") }
                let items = store.extensions.flatMap { $0.newMenuItems(for: GroupInfo(id: group.id, name: group.name, folder: group.dir)) }
                if !items.isEmpty { Divider() }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button { item.action() } label: { Label(item.title, systemImage: item.symbol ?? "puzzlepiece") }
                }
            }
            Divider()
            Button("Rename") { store.renamingGroupID = group.id }
            Menu("Color") {
                ForEach(0..<8, id: \.self) { i in
                    Button { store.setGroupColor(group.id, i) } label: {
                        Text((group.colorIndex == i ? "✓ " : "    ") + GroupPalette.names[i])
                    }
                }
            }
            Button("Startup command…") { store.editStartupCommand(group: group.id) }
            Divider()
            Button(collapsed ? "Expand" : "Collapse") { withAnimation(.snappy(duration: 0.2)) { store.toggleCollapsed(group.id) } }
            Button("Collapse or expand all") { withAnimation(.snappy(duration: 0.2)) { store.toggleAllCollapsed() } }
            Button((group.hideRecent ?? false) ? "Show recent sessions" : "Hide recent sessions") {
                withAnimation(.snappy(duration: 0.2)) { store.toggleRecentHidden(group.id) }
            }
            Button(store.olderShown.contains(group.id) ? "Hide older sessions" : "Show older sessions") {
                withAnimation(.snappy(duration: 0.2)) { store.toggleOlderShown(group.id) }
            }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: group.dir)) }
            Button("Delete group…", role: .destructive) { store.deleteGroup(group.id) }
        }
    }
}

/// The dots on a collapsed group: what its agents are doing, at a glance.
private struct GroupSummary: View {
    let states: [AgentState]
    let count: Int
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let working = states.filter { $0 == .working }.count
        let waiting = states.filter { $0 == .needsYou }.count
        let done = states.filter { $0 == .doneUnseen }.count
        HStack(spacing: 2) {
            if waiting > 0 { StatusDot(state: .needsYou, animated: store.settings.animations, size: 6) }
            if working > 0 { StatusDot(state: .working, animated: store.settings.animations, size: 6) }
            if done > 0 { StatusDot(state: .doneUnseen, size: 6) }
            if working + waiting + done == 0 {
                Text("\(count)").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
        }
    }
}

private struct SidebarTabRow: View {
    let group: GroupModel
    let tab: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        // Only the tab on screen is highlighted; other groups' remembered tabs look like any other row.
        let active = group.selectedTabID == tab.id && group.id == store.selectedGroupID
        let state = store.state(tab.id)
        HStack(spacing: 7) {
            ZStack {
                if state == .none {
                    Image(systemName: store.isSleeping(tab) ? "moon.zzz" : tab.kind.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                } else {
                    StatusDot(state: state, animated: store.settings.animations, size: 6)
                }
                if state != .needsYou, store.wantsAttention(tab) { AskRing(size: 13) }
            }
            .frame(width: 14)
            Text(store.title(for: tab))
                .font(.system(size: 12.5, weight: active ? .medium : .regular))
                .foregroundStyle(active ? theme.text : theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if store.settings.showPullRequests, store.onOwnBranch(tab, in: group), let pr = store.pullRequest(forDir: tab.cwd) {
                PullRequestBadge(pr: pr)
            }
            if store.isPinned(tab: tab, in: group.id) {
                Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(theme.muted)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? theme.selected : hovering ? theme.hover.opacity(0.6) : .clear))
        .activeOutline(active, radius: 6, dashed: true)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.selectTab(tab.id) }
        .draggable("tab:\(tab.id.uuidString)")
        .contextMenu { TabMenu(tab: tab) }
    }
}

private struct SidebarFooter: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Button { store.newGroup() } label: {
                Label("New group", systemImage: "plus").font(.system(size: 12.5))
            }
            .buttonStyle(.plain)
            Spacer()
            SettingsLink {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .hint("Settings (⌘,)")
        }
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Shared context menu for a tab, used by the sidebar and the tab strip.
struct TabMenu: View {
    let tab: TabModel
    @Environment(Store.self) private var store

    /// Three groups: the tab, its agent, closing. The agent group always has Show Browser Above, so no group is
    /// ever empty and dividers never double up.
    var body: some View {
        Button("Rename") { store.selectTab(tab.id, focus: false); store.renamingTabID = tab.id }
        if store.pinnableSession(tab) != nil, let group = store.groups.first(where: { $0.tabs.contains { $0.id == tab.id } }) {
            Button(store.isPinned(tab: tab, in: group.id) ? "Unpin" : "Pin to Top") {
                withAnimation(.snappy(duration: 0.2)) { store.togglePinnedTab(tab.id) }
            }
        }
        Menu("Move to Group") {
            ForEach(store.groups) { group in
                Button(group.name) { store.moveTab(tab.id, toGroup: group.id) }
            }
        }
        Divider()
        if tab.kind == .claude {
            if tab.claudeSessionId != nil {
                Button("Fork Session") { store.forkTab(tab.id) }
            }
            Button("Restart Claude (keeps the session)") { store.restartClaude(tab.id) }
                .disabled(store.claudeRestartCheck(tab.id) != .eligible)
        }
        Button((tab.showBrowser ?? false) ? "Hide Browser" : "Show Browser Above") { store.toggleBrowser(tab.id) }
        Divider()
        // Named by what happens to the agent: closing an agent tab stops it (the conversation is kept).
        Button([.claude, .codex].contains(tab.kind) ? "Close & Stop Agent" : "Close Tab") { store.closeTab(tab.id) }
        if tab.attachJobId != nil {
            Button("Close, Keep Agent Running") { store.closeTab(tab.id, keepAgent: true) }
        }
    }
}

/// Faded one-click buttons for Claude sessions recently active in this group's folder, then an Older fold for
/// the ones before that. Clicking one resumes it in a new tab. Recent folds away from its header and stays folded.
private struct RecentSessionsList: View {
    let group: GroupModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var showAll = false
    @State private var showAllOlder = false

    var body: some View {
        let sessions = store.recentSessions(for: group)
        let pinned = store.pinnedSessions(for: group)
        let showOlder = store.olderShown.contains(group.id)
        let olderCount = store.olderSessions(for: group)?.count ?? 0
        if !sessions.isEmpty || showOlder || !pinned.isEmpty || olderCount > 0 {
            let hidden = group.hideRecent ?? false
            let limit = 6
            VStack(alignment: .leading, spacing: 3) {
                // Pinned sessions sit at the top, always shown, whatever their age.
                ForEach(pinned) { session in
                    RecentSessionPill(session: session, groupID: group.id, pinned: true)
                }
                .padding(.top, pinned.first.map { _ in 4 } ?? 0)
                if !sessions.isEmpty { recent(sessions, hidden: hidden, limit: limit) }
                // Older shows when it's open, under a visible Recent list, or whenever the group has older sessions.
                if showOlder || (!sessions.isEmpty && !hidden) || olderCount > 0 { older(open: showOlder, limit: limit) }
            }
            .padding(.leading, 30)
            .padding(.trailing, 8)
            .transition(.opacity)
        }
    }

    @ViewBuilder private func older(open: Bool, limit: Int) -> some View {
        let older = store.olderSessions(for: group)
        fold(title: "Older", count: older?.count, open: open,
             hint: open ? "Hide older sessions" : "Show sessions from before the last \(Int(store.settings.recentSessionDays)) days") {
            store.toggleOlderShown(group.id)
        }
        if open {
            if let older, !older.isEmpty {
                ForEach(showAllOlder ? older : Array(older.prefix(limit))) { session in
                    RecentSessionPill(session: session, groupID: group.id)
                }
                if older.count > limit { moreButton(showAll: $showAllOlder, extra: older.count - limit) }
            } else {
                Text(older == nil ? "Looking…" : "None").font(.system(size: 10.5))
                    .foregroundStyle(theme.muted.opacity(0.8)).padding(.leading, 11)
            }
        }
    }

    private func fold(title: String, count: Int?, open: Bool, hint: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(.system(size: 10.5, weight: .medium))
                if let count { Text("\(count)").font(.system(size: 10.5)) }
                Spacer()
            }
            .foregroundStyle(theme.muted.opacity(0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(hint)
    }

    private func moreButton(showAll: Binding<Bool>, extra: Int) -> some View {
        Button(showAll.wrappedValue ? "Show fewer" : "\(extra) more") {
            withAnimation(.snappy(duration: 0.2)) { showAll.wrappedValue.toggle() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5))
        .foregroundStyle(theme.muted.opacity(0.8))
        .padding(.leading, 11)
    }

    @ViewBuilder private func recent(_ sessions: [RecentSession], hidden: Bool, limit: Int) -> some View {
        fold(title: "Recent", count: sessions.count, open: !hidden,
             hint: hidden ? "Show sessions from the last \(Int(store.settings.recentSessionDays)) days" : "Hide recent sessions") {
            store.toggleRecentHidden(group.id)
        }
        .padding(.top, 4)
        if !hidden {
            ForEach(showAll ? sessions : Array(sessions.prefix(limit))) { session in
                RecentSessionPill(session: session, groupID: group.id)
            }
            if sessions.count > limit { moreButton(showAll: $showAll, extra: sessions.count - limit) }
        }
    }
}

private struct RecentSessionPill: View {
    let session: RecentSession
    let groupID: UUID
    var pinned = false
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let live = store.liveSessionIds.contains(session.sessionId)
        Button { store.resumeRecentSession(session, in: groupID) } label: {
            HStack(spacing: 5) {
                Image(systemName: live ? "dot.radiowaves.left.and.right"
                      : pinned ? "pin.fill"
                      : session.agent == .codex ? TabKind.codex.symbol : "arrow.counterclockwise")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(session.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(session.lastActive, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 9.5))
                    .opacity(hovering ? 1 : 0)
            }
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(Capsule().fill(theme.hover))
            .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
            .opacity(hovering ? 0.95 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin to Top") {
                withAnimation(.snappy(duration: 0.2)) { store.togglePinned(session, in: groupID) }
            }
            // A session running as a background agent with no tab: stop it here (the conversation is kept).
            if let job = store.liveBackgroundJobs[session.sessionId] {
                Divider()
                Button("Stop Agent") { store.stopLiveBackgroundSession(session, job: job) }
            }
        }
        .help("Resume \(session.agent == .codex ? "Codex" : "Claude") session \(session.name) in a new tab"
              + (live ? " (it's running somewhere else right now)" : ""))
    }
}
