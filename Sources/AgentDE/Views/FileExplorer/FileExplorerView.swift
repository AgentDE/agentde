import AppKit
import Quartz
import SwiftUI

struct FileExplorerView: View {
    let tab: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @FocusState private var filterFocused: Bool
    @FocusState private var treeFocused: Bool

    var body: some View {
        let model = store.terminals.explorer(for: tab)
        @Bindable var bindable = model
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.muted)
                    TextField("Find a file in \(model.root.lastPathComponent)", text: $bindable.filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($filterFocused)
                        .onKeyPress(.escape) { model.filter = ""; treeFocused = true; return .handled }
                        .onKeyPress(.downArrow) { treeFocused = true; step(model, 1); return .handled }
                        .onSubmit { if let first = model.filtered.first { select(model, model.root.appendingPathComponent(first)) } }
                    Button { model.showHidden.toggle() } label: {
                        Image(systemName: model.showHidden ? "eye" : "eye.slash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.muted)
                    .hint(model.showHidden ? "Hide generated folders (.git, node_modules…)" : "Show generated folders (.git, node_modules…)")
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.muted)
                        .hint("Reload")
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                Divider().overlay(theme.border)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.filter.isEmpty {
                                ForEach(model.rows, id: \.node.id) { row in
                                    FileRow(name: row.node.name, url: row.node.url, depth: row.depth,
                                            isDirectory: row.node.isDirectory,
                                            expanded: model.expanded.contains(row.node.id),
                                            selected: model.selection == row.node.url)
                                        .id(row.node.id)
                                        .onTapGesture(count: 2) { row.node.isDirectory ? model.toggle(row.node) : open(row.node.url) }
                                        .onTapGesture {
                                            treeFocused = true
                                            if row.node.isDirectory { model.toggle(row.node) }
                                            select(model, row.node.url)
                                        }
                                        .contextMenu { FileMenu(url: row.node.url, root: model.root, tab: tab) }
                                }
                            } else {
                                ForEach(model.filtered, id: \.self) { path in
                                    let url = model.root.appendingPathComponent(path)
                                    FileRow(name: path, url: url, depth: 0, isDirectory: false, expanded: false,
                                            selected: model.selection == url)
                                        .id(url.path)
                                        .onTapGesture(count: 2) { open(url) }
                                        .onTapGesture { treeFocused = true; select(model, url) }
                                        .contextMenu { FileMenu(url: url, root: model.root, tab: tab) }
                                }
                                if model.filtered.isEmpty {
                                    Text("No files match").font(.system(size: 12)).foregroundStyle(theme.muted).padding(12)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selection) { _, url in
                        if let url { proxy.scrollTo(url.path) }
                    }
                }
                .focusable()
                .focused($treeFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { step(model, 1); return .handled }
                .onKeyPress(.upArrow) { step(model, -1); return .handled }
                .onKeyPress(.rightArrow) { expandSelection(model, true); return .handled }
                .onKeyPress(.leftArrow) { expandSelection(model, false); return .handled }
                .onKeyPress(.return) { if let url = model.selection { open(url) }; return .handled }
            }
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 520)
            .background(theme.sidebar.opacity(0.5))

            FilePreview(url: model.selection, root: model.root, tab: tab)
                .frame(minWidth: 280, maxWidth: .infinity)
        }
        .onAppear { if model.selection == nil { filterFocused = true } }
    }

    private func select(_ model: FileExplorerModel, _ url: URL) {
        model.selection = url
        store.setExplorerSelection(tab.id, url.path)
    }

    /// Moves the selection through whatever list is showing: the tree, or filter results.
    private func step(_ model: FileExplorerModel, _ delta: Int) {
        let urls = model.filter.isEmpty ? model.rows.map(\.node.url) : model.filtered.map { model.root.appendingPathComponent($0) }
        guard !urls.isEmpty else { return }
        let current = model.selection.flatMap { urls.firstIndex(of: $0) } ?? (delta > 0 ? -1 : urls.count)
        select(model, urls[max(0, min(urls.count - 1, current + delta))])
    }

    private func expandSelection(_ model: FileExplorerModel, _ open: Bool) {
        guard let url = model.selection, let row = model.rows.first(where: { $0.node.url == url }) else { return }
        if row.node.isDirectory, model.expanded.contains(row.node.id) != open {
            model.setExpanded(row.node, open)
        } else if !open {
            // Left on a file or closed folder: go to its parent folder.
            let parent = url.deletingLastPathComponent()
            if parent.path.hasPrefix(model.root.path), parent != model.root { select(model, parent) }
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

struct FileRow: View {
    let name: String
    let url: URL
    let depth: Int
    let isDirectory: Bool
    let expanded: Bool
    let selected: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(theme.muted)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: FileIcons.symbol(for: url, isDirectory: isDirectory, expanded: expanded))
                .font(.system(size: 11.5))
                .foregroundStyle(isDirectory ? Color(hex: 0x378ADD) : theme.muted)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12.5))
                .foregroundStyle(selected ? theme.text : theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 23)
        .background(Rectangle().fill(selected ? theme.selected : hovering ? theme.hover : .clear))
        .activeOutline(selected, radius: 0, dashed: true)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(url.path.abbreviatingHome)
    }
}

/// Actions for a file or folder: open it, show it elsewhere, or hand its path to Claude.
struct FileMenu: View {
    let url: URL
    let root: URL
    let tab: TabModel
    @Environment(Store.self) private var store

    var body: some View {
        Button("Open") { NSWorkspace.shared.open(url) }
        Button("Open in Cursor") { store.openInCursor(url.path) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm" {
            Button("Open in browser pane") { store.openInBrowserPane(tab.id, url) }
        }
        Divider()
        Button("Copy path") { copy(url.path) }
        Button("Copy relative path") { copy(relative) }
        Button("Send path to Claude") { store.sendPathToClaude(relative, from: tab.id) }
    }

    private var relative: String {
        url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Preview

private struct FilePreview: View {
    let url: URL?
    let root: URL
    let tab: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let url {
                    Image(systemName: FileIcons.symbol(for: url, isDirectory: url.hasDirectoryPath))
                        .font(.system(size: 12)).foregroundStyle(theme.muted)
                    Text(url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                    Spacer()
                    LabeledButton(title: "Open", symbol: "arrow.up.right.square", help: "Open in its default app") {
                        NSWorkspace.shared.open(url)
                    }
                    LabeledButton(title: "Cursor", symbol: "chevron.left.forwardslash.chevron.right", help: "Open in Cursor") {
                        store.openInCursor(url.path)
                    }
                    LabeledButton(title: "Finder", symbol: "folder", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else {
                    Text("Select a file to preview it").font(.system(size: 12.5)).foregroundStyle(theme.muted)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider().overlay(theme.border)
            if let url {
                if ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) {
                    MarkdownView(url: url)
                } else {
                    QuickLookView(url: url)
                }
            } else {
                AppLogo(size: 64).opacity(0.5).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Quick Look's own preview: code and text, Markdown, images, PDFs, HTML, video and more.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
