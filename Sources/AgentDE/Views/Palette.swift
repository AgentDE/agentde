import SwiftUI

private struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color?
    let state: AgentState
    /// An open question in the tab's workstream: sorted right after needs-you tabs.
    var asking = false
    let action: () -> Void
}

struct CommandPalette: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var items: [PaletteItem] {
        var all: [PaletteItem] = []
        for group in store.groups {
            let color = Color(nsColor: store.groupColor(group))
            for tab in group.tabs {
                let asking = store.wantsAttention(tab)
                let waiting = store.runtime[tab.id]?.waitingFor.map { " · " + Notifier.describeWaiting($0) } ?? (asking ? " · a question for you" : "")
                all.append(PaletteItem(id: tab.id.uuidString, title: store.title(for: tab), subtitle: group.name + waiting,
                                       symbol: tab.kind.symbol, color: color, state: store.state(tab.id), asking: asking) {
                    store.selectTab(tab.id)
                })
            }
            all.append(PaletteItem(id: group.id.uuidString, title: group.name, subtitle: "group · \(group.tabs.count) tabs",
                                   symbol: "square.stack", color: color, state: .none) {
                store.selectGroup(group.id)
            })
        }
        let actions: [(String, String, () -> Void)] = [
            ("New Claude tab", "sparkle", { store.startTab(kind: .claude) }),
            ("New shell tab", "terminal", { store.newTab(kind: .shell) }),
            ("New Codex tab", "chevron.left.forwardslash.chevron.right", { store.startTab(kind: .codex) }),
            ("New File Explorer tab", "folder", { store.newTab(kind: .files) }),
            ("New tab in worktree…", "arrow.triangle.branch", { store.newWorktreeTab() }),
            ("New group…", "folder.badge.plus", { store.newGroup() }),
            ("Toggle browser above tab", "globe", { store.toggleBrowser() }),
            ("Show diff", "plus.forwardslash.minus", { store.showDiff() }),
            ("Open folder in Cursor", "arrow.up.forward.app", { store.openInEditor() }),
            ("Search all sessions", "text.magnifyingglass", { store.searchOpen = true }),
            ("Find in this tab", "magnifyingglass", { if let id = store.activeTab?.id { store.terminals.find(id, .showFindInterface) } }),
            ("Fork Claude session into new tab", "arrow.triangle.branch", { store.forkTab() }),
            ("Open Agent View (claude agents)", "person.3", { store.newTab(kind: .command, command: "claude agents", transient: true) }),
            ("Rename tab", "pencil", { if let id = store.activeTab?.id { store.renamingTabID = id } }),
            ("Jump to next waiting tab", "bell", { store.jumpToAttention() }),
            ("Reopen closed tab", "arrow.uturn.backward", { store.reopenClosedTab() }),
        ] + AgentCatalog.all.map { agent in ("New \(agent.name) tab", TabKind.agent.symbol, { store.newAgentTab(agent) }) }
        for (title, symbol, action) in actions {
            all.append(PaletteItem(id: "action:" + title, title: title, subtitle: "action", symbol: symbol,
                                   color: nil, state: .none, action: action))
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // With no query, tabs that want attention come first: needs you → working → done → the rest.
        func urgency(_ item: PaletteItem) -> Int {
            if item.state == .needsYou { return 0 }
            if item.asking { return 1 }
            switch item.state {
            case .needsYou: return 0
            case .working: return 2
            case .doneUnseen: return 3
            case .none: return 4
            }
        }
        guard !q.isEmpty else {
            return all.enumerated().sorted { (urgency($0.element), $0.offset) < (urgency($1.element), $1.offset) }.map(\.element)
        }
        return all
            .compactMap { item -> (PaletteItem, Int)? in
                let score = fuzzyScore(q, item.title.lowercased() + " " + item.subtitle.lowercased())
                return score.map { (item, $0) }
            }
            .sorted { ($0.1, -urgency($0.0)) > ($1.1, -urgency($1.0)) }
            .map(\.0)
    }

    var body: some View {
        let results = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
                    TextField("Jump to a tab or group, or run an action", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { run(results) }
                        .onKeyPress(.downArrow) { move(1, results.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, results.count); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { _, _ in selection = 0 }
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                Divider().overlay(theme.border)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.prefix(60).enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { selection = index; run(results) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, value in proxy.scrollTo(value) }
                }
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.window))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if item.state != .none {
                    StatusDot(state: item.state, animated: store.animations)
                } else {
                    Image(systemName: item.symbol).font(.system(size: 12)).foregroundStyle(item.color ?? theme.secondary)
                }
            }
            .frame(width: 18)
            Text(item.title).font(.system(size: 13.5)).foregroundStyle(theme.text).lineLimit(1)
            Spacer()
            HStack(spacing: 5) {
                if let color = item.color, item.subtitle != "action" {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
                }
                Text(item.subtitle).font(.system(size: 12)).foregroundStyle(theme.muted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? theme.selected : .clear))
        .activeOutline(selected, radius: 8)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + min(count, 60)) % min(count, 60)
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selection) else { return }
        let action = results[selection].action
        close()
        DispatchQueue.main.async(execute: action)
    }

    private func close() {
        store.paletteOpen = false
        store.focusActiveTerminal()
    }

    /// Subsequence match: every query character must appear in order. Rewards contiguous runs and word starts.
    private func fuzzyScore(_ query: String, _ text: String) -> Int? {
        var score = 0
        var run = 0
        var textIndex = text.startIndex
        var previous: Character = " "
        for q in query {
            var found = false
            while textIndex < text.endIndex {
                let c = text[textIndex]
                textIndex = text.index(after: textIndex)
                if c == q {
                    run += 1
                    score += 1 + run * 2 + (previous == " " || previous == "_" || previous == "-" ? 6 : 0)
                    previous = c
                    found = true
                    break
                }
                run = 0
                previous = c
            }
            if !found { return nil }
        }
        return score - text.count / 8
    }
}
