import SwiftUI

/// A group showing several tabs at once: one tab strip over the panes, and the active pane's side panel on the
/// right. Each pane has a slim header (status, name, ✕ to take it out of the split).
struct SplitArea: View {
    let group: GroupModel
    let layout: PaneLayout
    let active: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                WithTabStrip { PaneNode(node: layout, path: [], groupID: group.id, activeID: active.id) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.panelVisible(active), geo.size.width >= 760 {
                    Rectangle().fill(theme.border).frame(width: 1)
                    SidePanel(tab: active).frame(width: min(max(active.panelWidth ?? 320, 240), 480))
                }
            }
        }
    }
}

/// One node of the layout: a pane, or two nodes with a draggable divider between them.
private struct PaneNode: View {
    let node: PaneLayout
    let path: [Bool]
    let groupID: UUID
    let activeID: UUID
    @Environment(Store.self) private var store
    @State private var liveRatio: Double?
    @State private var dragStart: Double?

    var body: some View {
        switch node {
        case .tab(let id):
            if let tab = store.tab(id) { PaneView(tab: tab, active: id == activeID) }
        case .split(let vertical, let ratio, let first, let second):
            GeometryReader { geo in
                let total = Double(vertical ? geo.size.height : geo.size.width) - 5
                let firstSize = max(80, min(total - 80, total * (liveRatio ?? ratio)))
                let handle = ResizeHandle(axis: vertical ? .vertical : .horizontal) { delta in
                    if dragStart == nil { dragStart = firstSize }
                    liveRatio = min(max((dragStart! + delta) / max(total, 1), 0.15), 0.85)
                } onEnd: {
                    if let liveRatio { store.setSplitRatio(liveRatio, at: path, in: groupID) }
                    liveRatio = nil
                    dragStart = nil
                }
                if vertical {
                    VStack(spacing: 0) {
                        PaneNode(node: first, path: path + [false], groupID: groupID, activeID: activeID).frame(height: firstSize)
                        handle
                        PaneNode(node: second, path: path + [true], groupID: groupID, activeID: activeID)
                    }
                } else {
                    HStack(spacing: 0) {
                        PaneNode(node: first, path: path + [false], groupID: groupID, activeID: activeID).frame(width: firstSize)
                        handle
                        PaneNode(node: second, path: path + [true], groupID: groupID, activeID: activeID)
                    }
                }
            }
        }
    }
}

/// A pane: its header, then the tab's viewer and terminal.
private struct PaneView: View {
    let tab: TabModel
    let active: Bool
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                StatusDot(state: store.state(tab.id), animated: store.animations, size: 6)
                Text(store.title(for: tab))
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? theme.text : theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { store.removePane(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.muted)
                .opacity(hovering || active ? 1 : 0)
                .hint("Take out of the split (the tab stays open) · ⌥⌘W")
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(active ? theme.selected : Color.clear)
            .overlay(alignment: .top) {
                if active, let group = store.selectedGroup {
                    Rectangle().fill(Color(nsColor: store.groupColor(group))).frame(height: 1.5)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 0.5) }
            .contentShape(Rectangle())
            .onTapGesture { store.selectTab(tab.id) }
            .onHover { hovering = $0 }
            TabPane(tab: tab, embedded: true).id(tab.id)
        }
        .opacity(active ? 1 : 0.94)
    }
}
