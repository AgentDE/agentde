import SwiftTerm
import SwiftUI

extension Store {
    /// Esc Esc in an idle Claude tab: Claude's menu for going back to an earlier message (as `/rewind`).
    func rewind(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, tab(id)?.kind == .claude, runtime[id]?.agentPresent == true, state(id) != .working else {
            NSSound.beep()
            return
        }
        // With a draft in Claude's input, Esc Esc would just erase it: leave it alone and say so.
        guard !draftInClaudeInput(id) else { return }
        terminals.sendKey(id, [0x1B])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.terminals.sendKey(id, [0x1B]) }
    }

    /// `/compact` in an idle Claude tab.
    func compact(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, tab(id)?.kind == .claude, runtime[id]?.agentPresent == true, state(id) != .working else {
            NSSound.beep()
            return
        }
        guard !draftInClaudeInput(id) else { return }   // /compact would be appended to it
        terminals.typeIntoTerminal(id, "/compact\r")
    }

    /// Whether Claude's input in this tab holds text you typed; if so, beeps and says why nothing happened.
    private func draftInClaudeInput(_ id: UUID) -> Bool {
        guard terminals.session(id)?.claudeInputHasDraft() == true else { return false }
        NSSound.beep()
        activityNote = "Claude's input has a draft: send or clear it first"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.activityNote?.hasPrefix("Claude's input has a draft") == true { self?.activityNote = nil }
        }
        return true
    }

    /// Claude's Agent View (`claude agents`) in a tab of its own.
    func openAgentView() {
        newTab(kind: .command, command: "claude agents", transient: true)
    }
}

/// Claude actions in the chat's top-right corner (Settings → Terminal turns them off; Agent View is in the palette). Faint icons at rest; with
/// the pointer over them, a small capsule with labels.
struct ChatTools: View {
    let tab: TabModel
    @Environment(Store.self) private var store
    @State private var hovering = false

    var body: some View {
        let idle = store.runtime[tab.id]?.agentPresent == true && store.state(tab.id) != .working
        ChatToolsRow(tools: [
            .init(symbol: "arrow.uturn.backward", label: "Rewind", help: "Go back to an earlier message (⌥⌘Z)", enabled: idle) { store.rewind(tab.id) },
            .init(symbol: "rectangle.compress.vertical", label: "Compact", help: "Compact the conversation (/compact)", enabled: idle) { store.compact(tab.id) },
            .init(symbol: "arrow.triangle.branch", label: "Fork", help: "Fork into a new tab (⌥⌘F)", enabled: tab.claudeSessionId != nil) { store.forkTab(tab.id) },
            .init(symbol: "arrow.clockwise", label: "Restart", help: "Restart Claude, keeping the session",
                  enabled: store.claudeRestartCheck(tab.id) == .eligible) { store.restartClaude(tab.id) },
        ], expanded: hovering)
        .onHover { hovering = $0 }
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
                .foregroundStyle(tool.enabled ? theme.text.opacity(expanded ? 0.9 : 1) : theme.muted.opacity(0.55))
                .disabled(!tool.enabled)
                .hint(tool.help)
            }
        }
        .padding(.horizontal, expanded ? 4 : 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.sidebar.opacity(expanded ? 0.96 : 0)))
        .overlay(Capsule().stroke(theme.border.opacity(expanded ? 1 : 0), lineWidth: 0.5))
        .shadow(color: .black.opacity(expanded ? 0.25 : 0), radius: 8, y: 2)
        .opacity(expanded ? 1 : 0.3)
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

/// Covers a tab while its Claude restarts, so the quit and relaunch don't flash by: "Restarting Claude", the
/// session kept, and a moving bar until the new Claude is back.
struct RestartCover: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: theme.terminalBackground).opacity(0.94))
            VStack(spacing: 10) {
                Image(systemName: "arrow.clockwise").font(.system(size: 20, weight: .medium)).foregroundStyle(theme.secondary)
                Text("Restarting Claude").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                Text("Same session, newest version").font(.system(size: 12)).foregroundStyle(theme.muted)
                ProgressView().progressViewStyle(.linear).frame(width: 180).tint(Theme.working)
            }
        }
        .contentShape(Rectangle())   // keys and clicks wait until it's back
    }
}

/// Reading Claude Code's input line from the screen: the bottom-most row that starts with `❯`. What follows it is
/// either Claude's suggestion, drawn dim ("Try …"), or text you typed.
enum ClaudeInput {
    struct Cell { let character: Character; let dim: Bool }

    /// True when the input holds typed text, false when it's empty, nil when no input line is on screen.
    static func hasDraft(rows: [[Cell]]) -> Bool? {
        // Blank: spaces, no-break spaces, and never-written cells (NUL).
        func blank(_ c: Character) -> Bool { c.isWhitespace || c == "\u{00A0}" || c.unicodeScalars.allSatisfy { $0.value < 0x20 } }
        for row in rows.reversed() {
            guard let start = row.firstIndex(where: { !blank($0.character) }) else { continue }
            guard row[start].character == "❯" else { continue }
            return row[(start + 1)...].contains { !blank($0.character) && !$0.dim }
        }
        return nil
    }
}

extension TerminalSession {
    /// Whether Claude's input line (on screen now) holds a typed draft; nil when it can't tell.
    func claudeInputHasDraft() -> Bool? { ClaudeInput.hasDraft(in: view.getTerminal()) }
}

extension ClaudeInput {
    static func hasDraft(in terminal: Terminal) -> Bool? {
        var rows: [[ClaudeInput.Cell]] = []
        for row in 0..<terminal.rows {
            var cells: [ClaudeInput.Cell] = []
            for col in 0..<terminal.cols {
                guard let data = terminal.getCharData(col: col, row: row) else { continue }
                cells.append(.init(character: terminal.getCharacter(for: data), dim: data.attribute.style.contains(.dim)))
            }
            rows.append(cells)
        }
        return ClaudeInput.hasDraft(rows: rows)
    }
}
