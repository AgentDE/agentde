import SwiftUI

/// The active group's tabs, with status dots, rename, drag to reorder, and the + menu for new tabs.
struct TabStrip: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    /// Width of the tabs themselves, so the strip is only that wide and + sits right after the last tab.
    @State private var tabsWidth: CGFloat = .infinity

    var body: some View {
        let group = store.selectedGroup
        let color = group.map { Color(nsColor: store.groupColor($0)) } ?? theme.border
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        if let group {
                            ForEach(Array(group.shownTabs.enumerated()), id: \.element.id) { index, tab in
                                TabChip(group: group, tab: tab, index: index, color: color).id(tab.id)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 2)
                    .background(GeometryReader { Color.clear.preference(key: TabsWidthKey.self, value: $0.size.width) })
                }
                // With more tabs than fit, the one you switch to (⌘1–9, ⌘J, the sidebar) scrolls into view.
                .onChange(of: group?.selectedTabID) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            .frame(maxWidth: tabsWidth)
            .layoutPriority(1)   // the tabs get the room they need before the trailing spacer
            .onPreferenceChange(TabsWidthKey.self) { tabsWidth = $0 }
            // Right after the last tab; when the tabs overflow, it stays at the strip's visible edge.
            // A click opens the choice of tab type; the keyboard shortcuts open each kind directly.
            Menu {
                NewTabItems()
                Button { store.newWorktreeTab() } label: { Label("Tab in Worktree…", systemImage: "arrow.triangle.branch") }
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
            .hint("New tab: Claude ⌘T, Codex ⌥⌘T, Shell ⇧⌘T, File Explorer ⇧⌘E")
            // Beside +: what this tab's viewer showed, to reopen once it's closed.
            if let tab = store.activeTab, tab.viewerItem == nil, !(tab.viewerHistory ?? []).isEmpty {
                ViewerHistoryMenu(tab: tab) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondary).padding(.horizontal, 4).frame(height: 24).contentShape(Rectangle())
                }
                .hint("Reopen in the viewer (⌘[)")
            }
            if store.settings.termi {
                TermiStrip(mood: TermiMood.of(store.runtime.values.map(\.state), quietFor: 0), animated: store.animations)
                    .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 12)
            }
        }
        .frame(height: store.settings.density == .compact ? 34 : 40)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 0.5) }
    }
}

private struct TabsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TabChip: View {
    let group: GroupModel
    let tab: TabModel
    let index: Int
    let color: Color
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        let active = group.selectedTabID == tab.id
        let state = store.state(tab.id)
        let compact = store.settings.density == .compact
        HStack(spacing: 6) {
            ZStack {
                // The icon carries the state: green working, amber needs you, blue done.
                StatusIcon(name: store.icon(for: tab), state: state, idle: NSColor(active ? color : theme.muted),
                           animated: store.animations, size: 12)
                if state != .needsYou, store.wantsAttention(tab) { AskRing(size: 14) }
                SparkleBurst(token: store.runtime[tab.id]?.sparkleToken ?? 0, firedAt: store.runtime[tab.id]?.sparkleAt, color: color)
            }
            .frame(width: 14)
            if store.renamingTabID == tab.id {
                RenameField(initial: store.title(for: tab)) { store.renameTab(tab.id, to: $0) }
                    .font(.system(size: 12.5))
                    .frame(width: 140)
            } else {
                Text(store.title(for: tab))
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? theme.text : theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }
            ZStack {
                if hovering {
                    Button { store.closeTab(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(theme.hover))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondary)
                    .hint("Close tab (⌘W)")
                } else if let key = index < 8 ? index + 1 : (index == group.shownTabs.count - 1 ? 9 : nil), !compact {
                    Text("⌘\(key)").font(.system(size: 10)).foregroundStyle(theme.muted.opacity(active ? 1 : 0))
                }
            }
            .frame(width: 22)
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: compact ? 26 : 29)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? theme.selected : hovering ? theme.hover : .clear))
        .activeOutline(active, radius: 8)
        .overlay(alignment: .leading) {
            if dropTarget { Rectangle().fill(color).frame(width: 2).offset(x: -2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.renamingTabID = tab.id }
        .onTapGesture { store.selectTab(tab.id) }
        .draggable("tab:\(tab.id.uuidString)") {
            Text(store.title(for: tab)).font(.system(size: 12.5)).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            for item in items where item.hasPrefix("tab:") {
                if let id = UUID(uuidString: String(item.dropFirst(4))) { store.moveTab(id, before: tab.id) }
            }
            return true
        } isTargeted: { dropTarget = $0 }
        .contextMenu { TabMenu(tab: tab) }
        .help((store.isSleeping(tab) ? "Resumes its \(store.agent(of: tab)?.name ?? "agent") session when you open it\n" : "")
              + (store.runtime[tab.id]?.waitingFor.map { "Needs you: " + Notifier.describeWaiting($0) + "\n" } ?? "")
              + tab.cwd.abbreviatingHome)
    }
}

/// The New tab choices (the tab strip's +, a group's New menu): every agent, then Shell and File Explorer.
struct NewTabItems: View {
    var groupID: UUID? = nil
    @Environment(Store.self) private var store

    private struct Choice: Identifiable { let id: String; let name: String; let symbol: String }

    var body: some View {
        ForEach(Agents.all.map { Choice(id: $0.id, name: $0.name, symbol: $0.symbol) }) { agent in
            Button { store.startTab(agent: agent.id, in: groupID) } label: { Label { Text(agent.name) } icon: { Image.icon(agent.symbol) } }
        }
        Button { store.newTab(kind: .shell, in: groupID) } label: { Label("Shell", systemImage: TabKind.shell.symbol) }
        Button { store.newTab(kind: .files, in: groupID) } label: { Label("File Explorer", systemImage: TabKind.files.symbol) }
    }
}
