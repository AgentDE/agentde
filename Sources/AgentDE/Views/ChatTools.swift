import SwiftTerm
import SwiftUI

extension Store {
    /// The agent a tab runs (`Agents.of`).
    func agent(of tab: TabModel) -> (any Agent)? { Agents.of(tab) }

    /// The active tab's action with this id (`rewind`, `compact`, `fork`), for the menu bar and palette; beeps when
    /// its agent has none.
    func runTool(_ actionID: String) {
        guard let tab = activeTab, let action = agent(of: tab)?.actions.first(where: { $0.id == actionID }) else {
            NSSound.beep()
            return
        }
        runTool(action, in: tab.id)
    }

    /// Keys and commands need the agent there (they do what typing them would, mid-turn too: Rewind's Esc Esc then
    /// stops the turn first, as it would from the keyboard). Code decides for itself.
    func toolEnabled(_ action: AgentAction, in tab: TabModel) -> Bool {
        switch action.run {
        // An agent that can't report itself (a plugin's without hooks) is taken to be there.
        case .keys, .command: runtime[tab.id]?.agentPresent == true || agent(of: tab) is PluginAgent
        case .code(let enabled, _): enabled(self, tab)
        }
    }

    func runTool(_ action: AgentAction, in id: UUID) {
        guard let tab = tab(id), toolEnabled(action, in: tab) else {
            NSSound.beep()
            return
        }
        switch action.run {
        case .code(_, let run):
            run(self, id)
        case .command(let command):
            // A draft in the input would have the command appended to it. An agent that can stash it (Claude's
            // Ctrl+S) sets it aside and brings it back after; otherwise the command waits.
            if hasDraft(tab) {
                guard let stash = agent(of: tab)?.definition.stash, !stash.isEmpty else {
                    noteDraft(tab)
                    return
                }
                terminals.sendKey(id, Array(stash.utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    _ = self?.terminals.typeIntoTerminal(id, command + "\r")
                }
                return
            }
            _ = terminals.typeIntoTerminal(id, command + "\r")
        case .keys(let keys):
            // Keys would erase a draft.
            guard !hasDraft(tab) else {
                noteDraft(tab)
                return
            }
            // A moment apart, so Esc Esc reads as two presses rather than one Alt+Esc.
            for (index, key) in keys.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(index)) { [weak self] in
                    self?.terminals.sendKey(id, Array(String(key).utf8))
                }
            }
        }
    }

    /// Whether the agent's input line (found by its `prompt`) holds text you typed.
    private func hasDraft(_ tab: TabModel) -> Bool {
        guard let prompt = agent(of: tab)?.definition.prompt?.first else { return false }
        return terminals.session(tab.id)?.inputHasDraft(prompt: prompt) == true
    }

    /// Beeps and says why a tool did nothing: the draft in the way.
    private func noteDraft(_ tab: TabModel) {
        guard let agent = agent(of: tab) else { return }
        NSSound.beep()
        activityNote = "\(agent.name)'s input has a draft: send or clear it first"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.activityNote?.hasSuffix("send or clear it first") == true { self?.activityNote = nil }
        }
    }
}

/// The tab's agent tools in the chat's top-right corner (Settings → Terminal turns them off). Quiet icons on a small backing at rest;
/// with the pointer over them, a small capsule with labels.
struct ChatTools: View {
    let tab: TabModel
    let actions: [AgentAction]
    @Environment(Store.self) private var store
    @State private var hovering = false

    var body: some View {
        ChatToolsRow(tools: actions.map { action in
            .init(symbol: action.symbol, label: action.label, help: action.help,
                  enabled: store.toolEnabled(action, in: tab)) { store.runTool(action, in: tab.id) }
        }, expanded: hovering)
        .onHover { hovering = $0 }
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
        .animation(.snappy(duration: 0.16), value: hovering)
        .padding(.top, 6)
        .padding(.trailing, 12)
    }
}

/// The row itself, separate from the store so it can be drawn on its own.
struct ChatToolsRow: View {
    struct Tool: Identifiable {
        let symbol: String
        let label: String
        let help: String
        let enabled: Bool
        let action: () -> Void
        var id: String { label }
    }

    let tools: [Tool]
    let expanded: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: expanded ? 2 : 6) {
            ForEach(tools) { tool in
                Button(action: tool.action) {
                    HStack(spacing: 4) {
                        Image(systemName: tool.symbol).font(.system(size: 10.5, weight: .semibold))
                        if expanded { Text(tool.label).font(.system(size: 11, weight: .medium)).fixedSize() }
                    }
                    .padding(.horizontal, expanded ? 7 : 2)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChatToolButtonStyle(expanded: expanded))
                // At rest: readable but quiet (muted); usable tools stay clearly brighter than ones that aren't.
                .foregroundStyle(tool.enabled ? (expanded ? theme.text.opacity(0.9) : theme.muted) : theme.muted.opacity(0.4))
                .disabled(!tool.enabled)
                .hint(tool.help)
            }
        }
        .padding(.horizontal, expanded ? 4 : 6)
        .padding(.vertical, 3)
        // A solid backing even at rest, so terminal text behind the row doesn't run through the icons.
        .background(Capsule().fill(expanded ? theme.sidebar.opacity(0.96) : Color(nsColor: theme.terminalBackground).opacity(0.92)))
        .overlay(Capsule().stroke(theme.border.opacity(expanded ? 1 : 0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(expanded ? 0.25 : 0), radius: 8, y: 2)
    }
}

/// A soft highlight under the button the pointer is on.
private struct ChatToolButtonStyle: ButtonStyle {
    let expanded: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(theme.text.opacity(configuration.isPressed ? 0.16 : hovering && expanded ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}

/// Covers a tab while its terminal is in flux, so the churn doesn't flash by: Claude restarting (until the new
/// Claude is back), or the tab reconnecting after a relaunch (until the replay and redraw are done).
struct LoadingCover: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: theme.terminalBackground).opacity(0.94))
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(theme.secondary)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(theme.muted)
                ProgressView().progressViewStyle(.linear).frame(width: 180).tint(Theme.working)
            }
        }
        .contentShape(Rectangle())   // keys and clicks wait until it's back
    }
}

/// Claude Code reports "busy" while it waits on background work (dynamic workflows, say) with its prompt open
/// and nothing running. A turn that's really running shows a spinner that redraws every second,
/// `✽ Zesting… (4m 43s · ↓ 15.4k tokens)`; when output has been quiet and no spinner is on screen, Claude is idle
/// whatever the registry says. (A finished turn reads `Baked for 59s · done`, which isn't a spinner.)
enum ClaudeActivity {
    /// The screen is read only once output has been quiet that long.
    static func looksIdle(screen: () -> [String], lastOutput: Date?, now: Date = Date(), quiet: TimeInterval = 5) -> Bool {
        guard let lastOutput, now.timeIntervalSince(lastOutput) >= quiet else { return false }
        return !screen().contains(where: isSpinner)
    }

    /// A word ending in "…", then the elapsed time in parentheses; or the older "esc to interrupt" hint.
    static func isSpinner(_ line: String) -> Bool {
        line.range(of: #"…\s*\((\d+h\s*)?(\d+m\s*)?\d+s\b"#, options: .regularExpression) != nil
            || line.localizedCaseInsensitiveContains("esc to interrupt")
    }
}

/// Reading an agent's input line from the screen: the bottom-most row that starts with its prompt (`❯` for
/// Claude Code). What follows is either a suggestion, drawn dim ("Try …"), or text you typed.
enum AgentInput {
    struct Cell { let character: Character; let dim: Bool }

    /// True when the input holds typed text, false when it's empty, nil when no input line is on screen.
    static func hasDraft(rows: [[Cell]], prompt: Character = "❯") -> Bool? {
        // Blank: spaces, no-break spaces, and never-written cells (NUL).
        func blank(_ c: Character) -> Bool { c.isWhitespace || c == "\u{00A0}" || c.unicodeScalars.allSatisfy { $0.value < 0x20 } }
        for row in rows.reversed() {
            guard let start = row.firstIndex(where: { !blank($0.character) }) else { continue }
            guard row[start].character == prompt else { continue }
            return row[(start + 1)...].contains { !blank($0.character) && !$0.dim }
        }
        return nil
    }
}

extension TerminalSession {
    /// Whether the agent's input line (on screen now) holds a typed draft; nil when it can't tell.
    func inputHasDraft(prompt: Character) -> Bool? { AgentInput.hasDraft(in: view.getTerminal(), prompt: prompt) }

    /// The screen's text, row by row.
    func screenText() -> [String] {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).map { row in
            String((0..<terminal.cols).compactMap { col in terminal.getCharData(col: col, row: row).map { terminal.getCharacter(for: $0) } })
        }
    }
}

extension AgentInput {
    static func hasDraft(in terminal: Terminal, prompt: Character) -> Bool? {
        var rows: [[AgentInput.Cell]] = []
        for row in 0..<terminal.rows {
            var cells: [AgentInput.Cell] = []
            for col in 0..<terminal.cols {
                guard let data = terminal.getCharData(col: col, row: row) else { continue }
                cells.append(.init(character: terminal.getCharacter(for: data), dim: data.attribute.style.contains(.dim)))
            }
            rows.append(cells)
        }
        return AgentInput.hasDraft(rows: rows, prompt: prompt)
    }
}
