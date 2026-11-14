import SwiftTerm
import SwiftUI

extension Store {
    /// The agent a tab runs: Claude and Codex are built in, the rest come from extensions and plugins.
    func agent(of tab: TabModel) -> AgentDefinition? {
        switch tab.kind {
        case .claude: AgentCatalog.claude
        case .codex: AgentCatalog.codex
        case .agent: AgentCatalog.definition(tab.agentID)
        default: nil
        }
    }

    /// The active tab's tool with this id (`rewind`, `compact`), for the menu and palette; beeps when it has none.
    func runTool(_ toolID: String) {
        guard let tab = activeTab, let tool = agent(of: tab)?.tools?.first(where: { $0.id == toolID }) else {
            NSSound.beep()
            return
        }
        runTool(tool, in: tab.id)
    }

    /// Keys and commands need the agent waiting for you. A built-in tool with neither is the app's own
    /// action: Fork and Restart, for Claude.
    func toolEnabled(_ tool: AgentTool, in tab: TabModel) -> Bool {
        guard tool.keys == nil, tool.command == nil else {
            return state(tab.id) != .working && (tab.kind == .agent || runtime[tab.id]?.agentPresent == true)
        }
        switch tool.id {
        case "fork": return tab.claudeSessionId != nil
        case "restart": return claudeRestartCheck(tab.id) == .eligible
        default: return false
        }
    }

    func runTool(_ tool: AgentTool, in id: UUID) {
        guard let tab = tab(id), toolEnabled(tool, in: tab) else {
            NSSound.beep()
            return
        }
        if tool.keys == nil, tool.command == nil {
            if tool.id == "fork" { forkTab(id) } else if tool.id == "restart" { restartClaude(id) }
            return
        }
        // With a draft in the agent's input, keys would erase it and a command would be appended to it.
        guard !draftInInput(tab) else { return }
        if let command = tool.command {
            _ = terminals.typeIntoTerminal(id, command + "\r")
            return
        }
        // A moment apart, so Esc Esc reads as two presses rather than one Alt+Esc.
        for (index, key) in (tool.keys ?? "").enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(index)) { [weak self] in
                self?.terminals.sendKey(id, Array(String(key).utf8))
            }
        }
    }

    /// Whether the agent's input line (found by its `prompt`) holds text you typed; if so, beeps and says why
    /// nothing happened.
    private func draftInInput(_ tab: TabModel) -> Bool {
        guard let agent = agent(of: tab), let prompt = agent.prompt?.first,
              terminals.session(tab.id)?.inputHasDraft(prompt: prompt) == true else { return false }
        NSSound.beep()
        activityNote = "\(agent.name)'s input has a draft: send or clear it first"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.activityNote?.hasSuffix("send or clear it first") == true { self?.activityNote = nil }
        }
        return true
    }

    /// Claude's Agent View (`claude agents`) in a tab of its own.
    func openAgentView() {
        newTab(kind: .command, command: "claude agents", transient: true)
    }
}

/// The tab's agent tools in the chat's top-right corner (Settings → Terminal turns them off). Faint icons at rest;
/// with the pointer over them, a small capsule with labels.
struct ChatTools: View {
    let tab: TabModel
    let tools: [AgentTool]
    @Environment(Store.self) private var store
    @State private var hovering = false

    var body: some View {
        ChatToolsRow(tools: tools.map { tool in
            .init(symbol: tool.symbol ?? "command", label: tool.label, help: tool.help ?? tool.command ?? tool.label,
                  enabled: store.toolEnabled(tool, in: tab)) { store.runTool(tool, in: tab.id) }
        }, expanded: hovering)
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
