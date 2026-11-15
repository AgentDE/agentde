import Foundation
import Testing
@testable import AgentDE

extension Data {
    /// A saved tab's JSON as the loader sees it, after `SavedStateMigration`.
    func migratedTab() throws -> Data {
        guard var raw = try JSONSerialization.jsonObject(with: self) as? [String: Any] else { return self }
        SavedStateMigration.tab(&raw)
        return try JSONSerialization.data(withJSONObject: raw)
    }
}

@Suite("Saved state from before agent tabs")
struct MigrationTests {
    /// Claude and Codex tabs become agent tabs, each keeping its session; shells keep Claude's; others are untouched.
    @Test func tabsBecomeAgentTabs() throws {
        func migrated(_ json: String) throws -> TabModel {
            try JSONDecoder().decode(TabModel.self, from: Data(json.utf8).migratedTab())
        }
        let id = UUID().uuidString
        let claude = try migrated(#"{"id": "\#(id)", "kind": "claude", "cwd": "/w", "claudeSessionId": "S1", "attachJobId": "abcd1234", "sessionName": "fix"}"#)
        #expect(claude.kind == .agent && claude.agentID == "claude" && claude.agentSession == "S1")
        #expect(claude.attachJobId == "abcd1234" && claude.sessionName == "fix")
        let codex = try migrated(#"{"id": "\#(id)", "kind": "codex", "cwd": "/w", "codexSessionId": "T1"}"#)
        #expect(codex.runs("codex") && codex.agentSession == "T1")
        let shell = try migrated(#"{"id": "\#(id)", "kind": "shell", "cwd": "/w", "claudeSessionId": "S2"}"#)
        #expect(shell.kind == .shell && shell.agentID == nil && shell.agentSession == "S2")
        let plugin = try migrated(#"{"id": "\#(id)", "kind": "agent", "agentID": "hello.gemini", "cwd": "/w"}"#)
        #expect(plugin.runs("hello.gemini") && plugin.agentSession == nil)
        // Already migrated: unchanged.
        var raw: [String: Any] = ["id": id, "kind": "agent", "agentID": "claude", "cwd": "/w", "agentSession": "S1"]
        #expect(SavedStateMigration.tab(&raw) == false)
    }

    @Test func defaultTabKindBecomesDefaultAgent() {
        var raw: [String: Any] = ["defaultTabKind": "codex", "fontSize": 13]
        #expect(SavedStateMigration.settings(&raw))
        #expect(raw["defaultAgent"] as? String == "codex" && raw["defaultTabKind"] == nil)
    }
}
