import AppKit
import SwiftUI

/// The side panel's Files tab: the tab folder's tree. A click on a file shows it in the viewer above the chat.
struct FilesPanel: View {
    let tab: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let model = store.terminals.explorer(for: tab)
        @Bindable var bindable = model
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.muted)
                TextField("Find a file", text: $bindable.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onKeyPress(.escape) { model.filter = ""; return .handled }
                    .onSubmit { if let first = model.filtered.first { open(model, model.root.appendingPathComponent(first)) } }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.muted)
                    .hint("Reload")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.filter.isEmpty {
                        ForEach(model.rows, id: \.node.id) { row in
                            FileRow(name: row.node.name, url: row.node.url, depth: row.depth, isDirectory: row.node.isDirectory,
                                    expanded: model.expanded.contains(row.node.id), selected: model.selection == row.node.url)
                                .onTapGesture { row.node.isDirectory ? model.toggle(row.node) : open(model, row.node.url) }
                                .contextMenu { FileMenu(url: row.node.url, root: model.root, tab: tab) }
                        }
                    } else {
                        ForEach(model.filtered, id: \.self) { path in
                            let url = model.root.appendingPathComponent(path)
                            FileRow(name: path, url: url, depth: 0, isDirectory: false, expanded: false, selected: model.selection == url)
                                .onTapGesture { open(model, url) }
                                .contextMenu { FileMenu(url: url, root: model.root, tab: tab) }
                        }
                        if model.filtered.isEmpty {
                            Text("No files match").font(.system(size: 12)).foregroundStyle(theme.muted).padding(12)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func open(_ model: FileExplorerModel, _ url: URL) {
        model.selection = url
        store.openInViewer(url.path, tab: tab.id)
    }
}

/// The side panel's Changes tab: what's changed in the tab's repository since the last commit, and the last
/// commits. A click shows the diff in the viewer. Read-only: committing and pushing are the agent's job.
struct ChangesPanel: View {
    let tab: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var root: String?
    @State private var changes: [GitChange] = []
    @State private var log: [GitCommit] = []
    @State private var loaded = false
    @State private var shown: String?
    /// The newest load; an older one finishing late is dropped.
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.secondary).lineLimit(1)
                if let branch = root.flatMap({ GitInfo.branch(at: $0) }) {
                    Text(branch).font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button { reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.muted)
                    .hint("Reload")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if loaded, root == nil {
                        note("Not a git repository")
                    } else if loaded {
                        heading(changes.isEmpty ? "No uncommitted changes" : "Uncommitted · \(changes.count)")
                        ForEach(changes) { change in
                            ChangeRow(change: change, selected: shown == "change:" + change.path) { showDiff(change) }
                        }
                        if !log.isEmpty {
                            heading("Commits")
                            ForEach(log) { commit in
                                CommitRow(commit: commit, selected: shown == "commit:" + commit.hash) { showCommit(commit) }
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .onAppear { reload() }
        .onChange(of: store.state(tab.id)) { _, _ in reload() }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).kerning(0.4)
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(theme.muted).padding(12)
    }

    private func reload() {
        let dir = tab.cwd
        generation += 1
        let mine = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitChanges.load(in: dir)
            DispatchQueue.main.async {
                guard mine == generation, dir == tab.cwd else { return }
                root = result?.root
                changes = result?.changes ?? []
                log = result?.log ?? []
                loaded = true
            }
        }
    }

    private func showDiff(_ change: GitChange) {
        guard let root else { return }
        shown = "change:" + change.path
        let name = URL(fileURLWithPath: change.path).lastPathComponent
        write(name: name + ".diff") { GitChanges.diff(change, root: root) }
    }

    private func showCommit(_ commit: GitCommit) {
        guard let root else { return }
        shown = "commit:" + commit.hash
        write(name: String(commit.hash.prefix(8)) + ".diff") { GitChanges.show(commit, root: root) }
    }

    /// Writes the diff to a file of the tab's own (the viewer shows files) and shows it.
    private func write(name: String, _ make: @escaping () -> String) {
        let id = tab.id
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentde-changes/\(id.uuidString.prefix(8))", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let text = make()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try? text.write(to: file, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { store.openInViewer(file.path, tab: id) }
        }
    }
}

private struct ChangeRow: View {
    let change: GitChange
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(change.status == "??" ? "N" : change.status)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(URL(fileURLWithPath: change.path).lastPathComponent)
                .font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(1)
            Text(URL(fileURLWithPath: change.path).deletingLastPathComponent().relativePath.replacingOccurrences(of: ".", with: ""))
                .font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if let added = change.added, added > 0 { Text("+\(added)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: 0x1D9E75)) }
            if let removed = change.removed, removed > 0 { Text("−\(removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: 0xE5534B)) }
        }
        .padding(.horizontal, 10)
        .frame(height: 23)
        .background(Rectangle().fill(selected ? theme.selected : hovering ? theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(change.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    /// What VoiceOver reads: the path, what happened to it, and the line counts.
    private var spoken: String {
        let what: String = switch change.status {
        case "??": "new"
        case "D": "deleted"
        case "A": "added"
        default: "modified"
        }
        let added = change.added.map { ", \($0) added" } ?? ""
        let removed = change.removed.map { ", \($0) removed" } ?? ""
        return change.path + ", " + what + added + removed
    }

    private var color: Color {
        switch change.status {
        case "??", "A": Color(hex: 0x1D9E75)
        case "D": Color(hex: 0xE5534B)
        case "U": Color(hex: 0xEF9F27)
        default: Color(hex: 0x378ADD)
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(commit.subject).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
            Text("\(commit.hash.prefix(7)) · \(commit.author) · \(Self.ago.localizedString(for: commit.date, relativeTo: Date()))")
                .font(.system(size: 10.5)).foregroundStyle(theme.muted).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(selected ? theme.selected : hovering ? theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(commit.subject)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// The side panel's Notifications tab: every needs-you and done event from this run, from all tabs, newest
/// first (`Store.notices`), whether or not its banner was shown. A click goes to the tab.
struct NotificationsPanel: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    /// nil shows every kind.
    @State private var kind: Notifier.Kind?

    var body: some View {
        let shown = store.notices.filter { kind == nil || $0.kind == kind }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("Show", selection: $kind) {
                    Text("All").tag(Notifier.Kind?.none)
                    Text("Needs you").tag(Notifier.Kind?.some(.needsYou))
                    Text("Done").tag(Notifier.Kind?.some(.done))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer(minLength: 0)
                Button("Clear") { store.clearNotices() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .disabled(store.notices.isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            if shown.isEmpty {
                Text(kind == nil ? "Agents that need you or finish show up here."
                     : kind == .needsYou ? "No agent has needed you yet." : "No agent has finished yet.")
                    .font(.system(size: 12)).foregroundStyle(theme.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { notice in
                            NoticeRow(notice: notice, exists: store.tab(notice.tab) != nil) { store.selectTab(notice.tab) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct NoticeRow: View {
    let notice: AgentNotice
    let exists: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(notice.kind == .needsYou ? Theme.needsYou : Theme.doneUnseen)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                Text(notice.body).font(.system(size: 11.5)).foregroundStyle(theme.secondary).lineLimit(2)
                Text("\(notice.group) · \(Date().timeIntervalSince(notice.date) < 60 ? "now" : Self.ago.localizedString(for: notice.date, relativeTo: Date()))")
                    .font(.system(size: 10.5)).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(exists ? 1 : 0.5)
        .background(Rectangle().fill(hovering && exists ? theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if exists { action() } }
        .help(exists ? notice.body : "This tab was closed")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if exists { action() } }
    }
}
