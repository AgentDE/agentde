import Foundation
import SQLite3
import Testing
@testable import AgentDE

@Suite("Recent Claude sessions")
struct RecentClaudeTests {
    let projects = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-recent-\(UUID().uuidString)")

    var jobs: URL { projects.appendingPathComponent("jobs") }
    var scanner: RecentSessionScanner { RecentSessionScanner(projectsDir: projects.appendingPathComponent("projects"), jobsDir: jobs) }

    @discardableResult
    func transcript(entrypoint: String, titles: [String]) throws -> String {
        let dir = projects.appendingPathComponent("projects/-tmp-repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = UUID().uuidString.lowercased()
        var lines = [#"{"type":"user","cwd":"/tmp/repo","entrypoint":"\#(entrypoint)","message":{"content":"hi"}}"#]
        lines += titles
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent(session + ".jsonl"), atomically: true, encoding: .utf8)
        return session
    }

    func job(_ session: String, name: String, fork: Bool = false) throws {
        let dir = jobs.appendingPathComponent(String(session.prefix(8)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state: [String: Any] = ["sessionId": session, "name": name, "nameSource": "auto", "template": "bg"]
        if fork { state["forkParentSessionId"] = "00000000-0000-0000-0000-000000000000" }
        try JSONSerialization.data(withJSONObject: state).write(to: dir.appendingPathComponent("state.json"))
    }

    /// A background session Claude Code named itself counts; a fork of another session doesn't.
    @Test func backgroundJobNamesCount() throws {
        defer { try? FileManager.default.removeItem(at: projects) }
        try job(try transcript(entrypoint: "cli", titles: []), name: "comment_translation_experiment_results")
        try job(try transcript(entrypoint: "cli", titles: []), name: "a fork", fork: true)
        let titled = try transcript(entrypoint: "cli", titles: [#"{"type":"custom-title","customTitle":"mine"}"#])
        try job(titled, name: "auto name")
        #expect(Set(scanner.scan(days: 14).map(\.name)) == ["comment_translation_experiment_results", "mine"])
    }

    @Test func onlyYourNamedSessionsAreListed() throws {
        try transcript(entrypoint: "cli", titles: [#"{"type":"custom-title","customTitle":"cold_budget_modeling"}"#])
        try transcript(entrypoint: "claude-desktop", titles: [#"{"type":"custom-title","customTitle":"Storage usage analysis"}"#])
        // Started by another agent: only an auto-generated agent name.
        try transcript(entrypoint: "cli", titles: [#"{"type":"agent-name","agentName":"Gameplay autoplay pilot eval"}"#])
        // Scripted SDK run, even if titled.
        try transcript(entrypoint: "sdk-py", titles: [#"{"type":"custom-title","customTitle":"archer review"}"#])
        let names = Set(scanner.scan(days: 14).map(\.name))
        #expect(names == ["cold_budget_modeling", "Storage usage analysis"])
    }

    @Test func aHugeFirstPromptStillCounts() throws {
        // The first user line is far longer than one read, as with a big paste.
        let dir = projects.appendingPathComponent("projects/-tmp-repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = String(repeating: "x", count: 300_000)
        let lines = [#"{"type":"permission-mode","mode":"default"}"#,
                     #"{"type":"user","cwd":"/tmp/repo","entrypoint":"cli","message":{"content":"\#(big)"}}"#,
                     #"{"type":"custom-title","customTitle":"game_making"}"#]
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("big.jsonl"), atomically: true, encoding: .utf8)
        let sessions = scanner.scan(days: 14)
        #expect(sessions.map(\.name) == ["game_making"] && sessions.first?.cwd == "/tmp/repo")
    }
}

@Suite("Recent Codex sessions")
struct RecentCodexTests {
    let codex = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-codex-\(UUID().uuidString)")

    func makeDatabase(_ rows: [(originator: String, source: String, name: String?, archived: Int, daysAgo: Double)]) throws {
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(codex.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE threads (id TEXT, name TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, source TEXT, originator TEXT)", nil, nil, nil)
        for row in rows {
            let name = row.name.map { "'\($0)'" } ?? "NULL"
            let updated = Int(Date().timeIntervalSince1970 - row.daysAgo * 86_400)
            sqlite3_exec(db, "INSERT INTO threads VALUES ('\(UUID().uuidString.lowercased())', \(name), '/tmp/repo', \(updated), \(row.archived), '\(row.source)', '\(row.originator)')", nil, nil, nil)
        }
    }

    @Test func onlyYourNamedThreadsAreListed() throws {
        try makeDatabase([
            ("codex-tui", "cli", "cold_play_budget", 0, 1),
            ("Codex Desktop", "vscode", "Diagnose MacBook sluggishness", 0, 2),
            ("codex-tui", "cli", nil, 0, 1),                                        // unnamed
            ("codex_exec", "exec", "review", 0, 1),                                  // agent-run
            ("Claude Code", "vscode", "Codex Companion Task: review", 0, 1),         // launched by Claude
            ("codex-tui", #"{"subagent":{"other":"guardian"}}"#, "guardian", 0, 1),  // sub-agent
            ("codex-tui", "cli", "archived one", 1, 1),
            ("codex-tui", "cli", "too old", 0, 30),
        ])
        let sessions = CodexSessionScanner(codexDir: codex).scan(days: 14)
        #expect(Set(sessions.map(\.name)) == ["cold_play_budget", "Diagnose MacBook sluggishness"])
        #expect(sessions.allSatisfy { $0.agent == .codex })
    }

    @Test func codexTabsResumeTheirThread() {
        var tab = TabModel(kind: .codex, cwd: "/tmp")
        #expect(TerminalSession.agentCommand(for: tab) == "codex")
        tab.codexSessionId = "01a13b8a-b9ad-7640-b3a2-21b7f2b944a9"
        #expect(TerminalSession.agentCommand(for: tab) == "codex resume 01a13b8a-b9ad-7640-b3a2-21b7f2b944a9")
        tab.codexSessionId = "x; rm -rf ~"
        #expect(TerminalSession.agentCommand(for: tab) == "codex")
    }
}
