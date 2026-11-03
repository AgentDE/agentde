import SwiftUI

/// The bar above the tabs: group name, folder, branch and PR, and the browser, diff and Cursor buttons.
struct HeaderBar: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            if !store.sidebarVisible {
                Color.clear.frame(width: 64)
                IconButton(symbol: "sidebar.left", help: "Show sidebar (⌘0)") { store.sidebarVisible = true }
            }
            if let group = store.selectedGroup {
                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                let dir = store.activeTab?.cwd ?? group.dir
                Text((dir as NSString).lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover))
                    .help(dir.abbreviatingHome)
                if let branch = GitInfo.branch(at: dir) {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if store.settings.showPullRequests, let pr = store.pullRequest(forDir: dir) {
                    PullRequestChip(pr: pr)
                }
            }
            Spacer(minLength: 12)
            let activeTab = store.activeTab
            if let activeTab, activeTab.viewerItem == nil, !(activeTab.viewerHistory ?? []).isEmpty {
                ViewerHistoryMenu(tab: activeTab) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 24).foregroundStyle(theme.secondary).contentShape(Rectangle())
                }
                .hint("Reopen in the viewer (⌘[)")
            }
            IconButton(symbol: "globe", help: "Browser above tab (⌘⇧B)",
                       active: activeTab?.showBrowser ?? false) { store.toggleBrowser() }
            IconButton(symbol: "plus.forwardslash.minus", help: "Show diff (⌘⇧D)") { store.showDiff() }
            IconButton(symbol: "arrow.up.forward.app", help: "Open folder in Cursor (⌘⇧O)") { store.openInEditor() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 40)
        .background {
            ZStack {
                WindowDragArea()
            }
        }
    }
}

/// Lets the custom header act as the window's title bar for dragging and double-click zoom.

private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
