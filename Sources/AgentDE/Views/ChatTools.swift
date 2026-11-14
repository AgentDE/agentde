import SwiftUI

extension Store {
    /// Esc Esc in an idle Claude tab: Claude's menu for going back to an earlier message (as `/rewind`).
    func rewind(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, tab(id)?.kind == .claude, runtime[id]?.agentPresent == true, state(id) != .working else {
            NSSound.beep()
            return
        }
        terminals.sendKey(id, [0x1B])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.terminals.sendKey(id, [0x1B]) }
    }

    /// `/compact` in an idle Claude tab.
    func compact(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, tab(id)?.kind == .claude, runtime[id]?.agentPresent == true, state(id) != .working else {
            NSSound.beep()
            return
        }
        terminals.typeIntoTerminal(id, "/compact\r")
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
