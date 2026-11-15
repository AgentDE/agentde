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
            .draggable("tab:\(tab.id.uuidString)") {
                Text(store.title(for: tab)).font(.system(size: 12.5)).padding(6)
            }
            TabPane(tab: tab, embedded: true).id(tab.id).tabDropZones(tab.id)
        }
        .opacity(active ? 1 : 0.94)
    }
}

extension View {
    /// Drop a tab here to see it beside this one: the edge nearest the pointer lights up, and the drop splits there.
    func tabDropZones(_ target: UUID) -> some View { modifier(TabDropZones(target: target)) }
}

private struct TabDropZones: ViewModifier {
    let target: UUID
    @Environment(Store.self) private var store
    @State private var edge: Edge?
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                Color.clear.onAppear { size = geo.size }.onChange(of: geo.size) { _, new in size = new }
            })
            .overlay { if let edge { DropHighlight(edge: edge) } }
            .onDrop(of: [.plainText], delegate: TabDropDelegate(size: size, edge: $edge) { id, edge in
                store.dropTab(id, onto: target, edge: edge)
            })
    }
}

private struct TabDropDelegate: DropDelegate {
    let size: CGSize
    @Binding var edge: Edge?
    let drop: (UUID, Edge) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { edge = nearest(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = nearest(info.location)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = nearest(info.location)
        edge = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let drop = drop
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix("tab:"), let id = UUID(uuidString: String(text.dropFirst(4))) else { return }
            DispatchQueue.main.async { drop(id, where_) }
        }
        return true
    }

    private func nearest(_ point: CGPoint) -> Edge {
        let w = max(size.width, 1), h = max(size.height, 1)
        let distances: [(Edge, CGFloat)] = [(.leading, point.x / w), (.trailing, 1 - point.x / w),
                                            (.top, point.y / h), (.bottom, 1 - point.y / h)]
        return distances.min { $0.1 < $1.1 }!.0
    }
}

/// The half a dropped tab would take.
private struct DropHighlight: View {
    let edge: Edge

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let rect: CGRect = switch edge {
            case .leading: CGRect(x: 0, y: 0, width: w / 2, height: h)
            case .trailing: CGRect(x: w / 2, y: 0, width: w / 2, height: h)
            case .top: CGRect(x: 0, y: 0, width: w, height: h / 2)
            case .bottom: CGRect(x: 0, y: h / 2, width: w, height: h / 2)
            }
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.doneUnseen.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.doneUnseen.opacity(0.8), lineWidth: 1.5))
                .padding(6)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.12), value: edge)
    }
}
