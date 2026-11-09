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
        let top = store.settings.tabsPosition == .top
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    if let group {
                        ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabChip(group: group, tab: tab, index: index, color: color)
                        }
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .background(GeometryReader { Color.clear.preference(key: TabsWidthKey.self, value: $0.size.width) })
            }
            .frame(maxWidth: tabsWidth)
            .layoutPriority(1)   // the tabs get the room they need before the trailing spacer
            .onPreferenceChange(TabsWidthKey.self) { tabsWidth = $0 }
            // Right after the last tab; when the tabs overflow, it stays at the strip's visible edge.
            // A click opens the choice of tab type; the keyboard shortcuts open each kind directly.
            Menu {
                ForEach([TabKind.claude, .codex, .shell, .files], id: \.self) { kind in
                    Button { store.newTab(kind: kind) } label: {
                        Label(kind == .files ? "File Explorer" : kind.label, systemImage: kind.symbol)
                    }
                }
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
            Spacer(minLength: 12)
        }
        .frame(height: store.settings.density == .compact ? 34 : 40)
        .overlay(alignment: top ? .top : .bottom) { Rectangle().fill(color).frame(height: 2) }
        .overlay(alignment: top ? .bottom : .top) { Rectangle().fill(theme.border).frame(height: 0.5) }
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
                if state == .none {
                    Image(systemName: store.isSleeping(tab) ? "moon.zzz" : tab.kind.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(active ? color : theme.muted)
                } else {
                    StatusDot(state: state, animated: store.settings.animations)
                }
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
                } else if index < 9, !compact {
                    Text("⌘\(index + 1)").font(.system(size: 10)).foregroundStyle(theme.muted.opacity(active ? 1 : 0))
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
        .help((store.isSleeping(tab) ? "Resumes its \(tab.kind == .codex ? "Codex" : "Claude") session when you open it\n" : "")
              + (store.runtime[tab.id]?.waitingFor.map { "Needs you: " + Notifier.describeWaiting($0) + "\n" } ?? "")
              + tab.cwd.abbreviatingHome)
    }
}
