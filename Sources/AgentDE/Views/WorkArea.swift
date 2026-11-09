import SwiftUI

/// The selected group's content: its active tab.
struct WorkArea: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let group = store.selectedGroup, let active = group.tabs.first(where: { $0.id == group.selectedTabID }) ?? group.tabs.first {
            TabPane(tab: active).id(group.id)
        } else {
            WithTabStrip { EmptyGroupView() }
        }
    }
}

/// A column with the tab strip above (or below, per Settings) its content.
struct WithTabStrip<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if store.settings.tabsPosition == .top { TabStrip() }
            content
            if store.settings.tabsPosition == .bottom { TabStrip() }
        }
    }
}

private struct TabPane: View {
    let tab: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    @State private var dragViewerHeight: Double?
    @State private var viewerDragStart: Double?
    @State private var dragPanelWidth: Double?
    @State private var panelDragStart: Double?
    @State private var panelOverlay = false

    var body: some View {
        if tab.kind == .files || tab.kind == .command {
            WithTabStrip { terminalStack }
        } else {
            GeometryReader { geo in
                let showPanel = store.panelVisible(tab)
                let narrow = geo.size.width < 760
                HStack(spacing: 0) {
                    WithTabStrip { mainColumn(height: geo.size.height) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showPanel {
                        if narrow {
                            PanelStrip(tab: tab) { panelOverlay.toggle() }
                        } else {
                            let width = panelWidth(available: geo.size.width)
                            ResizeHandle(axis: .horizontal) { delta in
                                if panelDragStart == nil { panelDragStart = width }
                                dragPanelWidth = clampPanel(panelDragStart! - delta, available: geo.size.width)
                            } onEnd: {
                                if let dragPanelWidth { store.setPanelWidth(tab.id, dragPanelWidth) }
                                dragPanelWidth = nil
                                panelDragStart = nil
                            }
                            panel.frame(width: width)
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if showPanel, narrow, panelOverlay {
                        panel
                            .frame(width: min(300, geo.size.width - 48))
                            .background(theme.window)
                            .shadow(color: .black.opacity(0.3), radius: 12, x: -2)
                            .padding(.trailing, 28)
                    }
                }
            }
        }
    }

    private var panel: some View { SidePanel(tab: tab) }

    private func clampPanel(_ width: Double, available: CGFloat) -> Double {
        min(max(width, 240), max(240, min(560, Double(available) * 0.5)))
    }

    private func panelWidth(available: CGFloat) -> Double {
        clampPanel(dragPanelWidth ?? tab.panelWidth ?? 320, available: available)
    }

    /// The viewer (when it shows something) above the chat, with a divider between them.
    @ViewBuilder private func mainColumn(height: CGFloat) -> some View {
        if let item = tab.viewerItem {
            if tab.viewerExpanded == true {
                ViewerArea(tab: tab, item: item)
            } else {
                let limit = max(120, Double(height) - 160)
                let viewerHeight = min(max(dragViewerHeight ?? tab.viewerHeight ?? Double(height) * 0.45, 120), limit)
                VStack(spacing: 0) {
                    ViewerArea(tab: tab, item: item).frame(height: viewerHeight)
                    ResizeHandle(axis: .vertical) { delta in
                        if viewerDragStart == nil { viewerDragStart = viewerHeight }
                        dragViewerHeight = min(max(viewerDragStart! + delta, 120), limit)
                    } onEnd: {
                        if let dragViewerHeight { store.setViewerHeight(tab.id, dragViewerHeight) }
                        dragViewerHeight = nil
                        viewerDragStart = nil
                    }
                    terminalStack
                }
            }
        } else {
            terminalStack
        }
    }

    /// The tab's terminal (or File Explorer), with the browser pane above it when that's open.
    @ViewBuilder private var terminalStack: some View {
        if tab.showBrowser ?? false {
            VSplitView {
                BrowserPane(tab: tab, store: store)
                    .id(tab.id)
                    .frame(minHeight: 120, maxHeight: .infinity)
                terminal.frame(minHeight: 120, maxHeight: .infinity)
            }
        } else {
            terminal
        }
    }

    @ViewBuilder private var terminal: some View {
        if tab.kind == .files {
            FileExplorerView(tab: tab).id(tab.id)
        } else {
            terminalPane
        }
    }

    private var terminalPane: some View {
        TerminalPane(tab: tab, store: store)
            .id(tab.id)
            .padding(.leading, 10)
            .padding(.top, 6)
            .background(Color(nsColor: Theme.resolve(store.settings.theme, dark: TerminalSession.isDark(store.settings)).terminalBackground))
    }
}

/// A thin divider that resizes what's beside it; reports the drag distance (down or right is positive).
private struct ResizeHandle: View {
    let axis: Axis
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? theme.border : Color.clear)
            .frame(width: axis == .horizontal ? 5 : nil, height: axis == .vertical ? 5 : nil)
            // A full point, so it shows even where both sides are the same black.
            .overlay { Rectangle().fill(theme.border).frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil) }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in onDrag(Double(axis == .vertical ? value.translation.height : value.translation.width)) }
                .onEnded { _ in onEnd() })
    }
}

/// The side panel folded to a strip on a narrow window: the tab's status, and a ring when an extension wants
/// attention.
private struct PanelStrip: View {
    let tab: TabModel
    let action: () -> Void
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                StatusDot(state: store.state(tab.id), animated: store.settings.animations, size: 6)
                if store.wantsAttention(tab) { AskRing(size: 10) }
                Spacer()
            }
            .padding(.top, 10)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(theme.sidebar.opacity(0.55))
        .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 0.5) }
        .hint("Show the side panel")
    }
}

private struct EmptyGroupView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            AppLogo(size: 96, wiggleOnHover: true)
            Text("Start a tab in this group").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.text)
            HStack(spacing: 10) {
                Button("Claude  ⌘T") { store.newTab(kind: .claude) }
                Button("Shell  ⌘⇧T") { store.newTab(kind: .shell) }
                Button("Codex") { store.newTab(kind: .codex) }
                Button("Files  ⌘⇧E") { store.newTab(kind: .files) }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
