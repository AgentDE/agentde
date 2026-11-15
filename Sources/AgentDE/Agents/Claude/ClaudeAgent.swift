import AgentDEKit
import Foundation

/// Claude Code. New sessions take their name (`--name`), tabs resume (`--resume`) and fork (`--fork-session`),
/// and a tab on one of Claude's background sessions attaches to it (`claude attach`).
struct ClaudeAgent: Agent {
    static let shared = ClaudeAgent()
    static let id = "claude"

    let definition = AgentDefinition(id: ClaudeAgent.id, name: "Claude", command: "claude", tools: [
        .init(id: "rewind", label: "Rewind", symbol: "arrow.uturn.backward", keys: "\u{1B}\u{1B}", help: "Go back to an earlier message (⌥⌘Z)"),
        .init(id: "compact", label: "Compact", symbol: "rectangle.compress.vertical", command: "/compact", help: "Compact the conversation (/compact)"),
    ], prompt: "❯", stash: "\u{13}", symbol: "sparkle")

    var namesSessions: Bool { true }
    func sessionScanner() -> SessionScanner? { ClaudeSessionScanner() }
    var transcript: TranscriptFormat? { ClaudeTranscript() }
    func lastReply(session: String, cwd: String) -> String? { TranscriptPeek.lastAssistantText(sessionId: session, cwd: cwd) }
    func liveBackgroundJob(session: String, store: Store) -> String? { store.liveBackgroundJobs[session] }

    func command(for tab: TabModel) -> String? {
        // Ids are validated before they reach the shell; an invalid one is treated as absent.
        if let job = SafeID.job(tab.attachJobId) { return "claude attach \(job)" }
        let session = SafeID.session(tab.agentSession)
        guard tab.kind == .agent else { return session.map { "claude --resume \($0)" } }   // Claude in a shell tab
        // A new session takes its name (`--name`): a fresh one, or a fork; a plain resume keeps its own.
        let name = tab.sessionName.flatMap { $0.isEmpty ? nil : " --name " + TerminalSession.shellQuoted($0) } ?? ""
        let flags = session.map { " --resume \($0)" + (tab.forkOnStart == true ? " --fork-session" + name : "") } ?? name
        return "claude" + flags
    }

    var actions: [AgentAction] {
        (definition.tools ?? []).compactMap(AgentAction.init) + [
            AgentAction(id: "fork", label: "Fork", symbol: "arrow.triangle.branch", help: "Fork into a new tab (⌥⌘F)",
                        run: .code(enabled: { _, tab in tab.agentSession != nil }, run: { store, id in store.forkTab(id) })),
            AgentAction(id: "restart", label: "Restart", symbol: "arrow.clockwise", help: "Restart Claude, keeping the session",
                        run: .code(enabled: { store, tab in store.claudeRestartCheck(tab.id) == .eligible },
                                   run: { store, id in store.restartClaude(id) })),
        ]
    }
}
