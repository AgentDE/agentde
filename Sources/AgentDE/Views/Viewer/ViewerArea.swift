import SwiftUI

/// The viewer above a tab's chat: a slim header (name, path, pin, fill the tab, close) over the item.
struct ViewerArea: View {
    let tab: TabModel
    let item: String
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        let expanded = tab.viewerExpanded ?? false
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ViewerHistoryMenu(tab: tab) {
                    HStack(spacing: 3) {
                        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                        if (tab.viewerHistory?.count ?? 0) > 1 {
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.muted)
                        }
                    }
                }
                .hint("Recent in this tab (⌘[ back, ⌘] forward)")
                Text(item.hasPrefix("http") ? item : item.abbreviatingHome)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if ViewerKind.of(item) == .markdown {
                    let raw = tab.viewerRaw == true
                    Button { store.toggleViewerRaw(tab.id) } label: {
                        Text("Raw").font(.system(size: 11.5, weight: raw ? .semibold : .medium))
                            .foregroundStyle(raw ? theme.text : theme.secondary)
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(raw ? theme.selected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hint(raw ? "Show it rendered" : "Show the Markdown text")
                }
                // Files also reload by themselves when they change on disk; pages don't.
                IconButton(symbol: "arrow.clockwise", help: "Reload") { store.terminals.viewers.host(for: tab.id).reload() }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: item.hasPrefix("http") ? "Copy link" : "Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                if item.hasPrefix("http"), let url = URL(string: ViewerLinks.openURL(item)) {
                    IconButton(symbol: "safari", help: "Open in browser") { NSWorkspace.shared.open(url) }
                }
                if let info = store.tabInfo(tab.id) {
                    ForEach(Array(store.extensions.compactMap { $0.viewerAccessory(for: info, item: item) }.enumerated()), id: \.offset) { $0.element }
                }
                IconButton(symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: expanded ? "Show the chat" : "Fill the tab") { store.toggleViewerExpanded(tab.id) }
                IconButton(symbol: "xmark", help: "Close (Esc)") { store.closeViewer(tab.id) }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 0.5) }
            if store.viewerFindTab == tab.id, ViewerKind.of(item).findable {
                ViewerFindBar(tabID: tab.id)
            }
            ViewerPane(tabID: tab.id, item: item, store: store)
        }
        .background(theme.sidebar.opacity(0.35))
    }

    private var title: String {
        if ViewerLinks.isViewerLink(item) {
            let info = store.tabInfo(tab.id)
            return info.flatMap { info in store.extensions.lazy.compactMap { $0.title(forLink: item, in: info) }.first }
                ?? ViewerLinks.title(for: item)
        }
        if item.hasPrefix("http"), let url = URL(string: item) { return url.host.map { "\($0)\(url.port.map { ":\($0)" } ?? "")" } ?? item }
        return (item as NSString).lastPathComponent
    }
}

/// ⌘F in the viewer: a field under its header. Return finds the next match (⇧Return the previous), as do ⌘G
/// and ⌘⇧G; Esc or Done closes it.
private struct ViewerFindBar: View {
    let tabID: UUID
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var term = ""
    @State private var notFound = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.muted)
            TextField("Find", text: $term)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { close() }
            if notFound { Text("Not found").font(.system(size: 11)).foregroundStyle(theme.muted) }
            IconButton(symbol: "chevron.up", help: "Previous (⌘⇧G)") { find(backwards: true) }
            IconButton(symbol: "chevron.down", help: "Next (⌘G)") { find(backwards: false) }
            Button("Done") { close() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 6)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 0.5) }
        .onAppear { focused = true }
        .onChange(of: store.viewerFindFocus) { focused = true }
        .onChange(of: store.viewerFindStep) { find(backwards: store.viewerFindBackwards) }
        .onChange(of: term) { find(backwards: false, incremental: true) }
    }

    private func find(backwards: Bool, incremental: Bool = false) {
        let searched = term
        store.terminals.viewers.host(for: tabID).find(searched, backwards: backwards, incremental: incremental) { found in
            if searched == term { notFound = !found }
        }
    }

    private func close() {
        store.viewerFindTab = nil
        store.terminals.viewers.existing(tabID)?.focusContent()
    }
}

/// The tab's viewer history as a menu: pick an item to show it again; the ✕ section forgets one.
struct ViewerHistoryMenu<Label: View>: View {
    let tab: TabModel
    @ViewBuilder let label: () -> Label
    @Environment(Store.self) private var store

    var body: some View {
        let history = tab.viewerHistory ?? []
        Menu {
            ForEach(history, id: \.self) { item in
                Button((item == tab.viewerItem ? "✓ " : "    ") + Self.name(item)) {
                    store.openInViewer(item, tab: tab.id, select: false)
                }
            }
            if !history.isEmpty {
                Divider()
                Menu("Forget") {
                    ForEach(history, id: \.self) { item in Button(Self.name(item)) { store.forgetViewerItem(item, tab: tab.id) } }
                }
            }
        } label: { label() }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(history.isEmpty)
    }

    /// "REPORT.md — ~/proj/docs", or a page's title and host.
    static func name(_ item: String) -> String {
        if item.hasPrefix("http") {
            let host = URL(string: item)?.host ?? item
            return ViewerLinks.isViewerLink(item) ? "\(ViewerLinks.title(for: item)) — \(host)" : host + (URL(string: item)?.path ?? "")
        }
        return (item as NSString).lastPathComponent + " — " + ((item as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}
