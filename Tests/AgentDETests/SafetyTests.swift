import Foundation
import Testing
@testable import AgentDE

@Suite("Ids that reach the shell")
struct SafeIDTests {
    @Test func sessionIdsMustBeUUIDs() {
        #expect(SafeID.session("6E6EBD7E-D01C-4352-ACFD-67B044CFC314") == "6e6ebd7e-d01c-4352-acfd-67b044cfc314")
        #expect(SafeID.session("x; rm -rf ~") == nil)
        #expect(SafeID.session("") == nil)
        #expect(SafeID.session(nil) == nil)
    }

    @Test func jobIdsMustBeShortHex() {
        #expect(SafeID.job("72cdb45d") == "72cdb45d")
        #expect(SafeID.job("72cdb45d; echo hi") == nil)
        #expect(SafeID.job("abc") == nil)
        #expect(SafeID.job(String(repeating: "a", count: 41)) == nil)
    }
}

@Suite("Agent launch commands")
struct AgentCommandTests {
    let session = "6e6ebd7e-d01c-4352-acfd-67b044cfc314"

    @Test func claudeTabResumesItsSession() {
        var tab = TabModel(kind: .claude, cwd: "/tmp")
        #expect(TerminalSession.agentCommand(for: tab) == "claude")
        tab.claudeSessionId = session
        #expect(TerminalSession.agentCommand(for: tab) == "claude --resume \(session)")
        tab.forkOnStart = true
        #expect(TerminalSession.agentCommand(for: tab) == "claude --resume \(session) --fork-session")
    }

    @Test func attachingWinsOverResuming() {
        var tab = TabModel(kind: .claude, cwd: "/tmp")
        tab.claudeSessionId = session
        tab.attachJobId = "6e6ebd7e"
        #expect(TerminalSession.agentCommand(for: tab) == "claude attach 6e6ebd7e")
    }

    @Test func invalidIdsNeverReachTheShell() {
        var tab = TabModel(kind: .shell, cwd: "/tmp")
        tab.claudeSessionId = "$(touch /tmp/pwned)"
        tab.attachJobId = "zz; ls"
        #expect(TerminalSession.agentCommand(for: tab) == nil)
    }

    @Test func plainShellsRunNoAgent() {
        #expect(TerminalSession.agentCommand(for: TabModel(kind: .shell, cwd: "/tmp")) == nil)
        #expect(TerminalSession.agentCommand(for: TabModel(kind: .files, cwd: "/tmp")) == nil)
    }
}

@Suite("Background sessions")
struct BackgroundSessionTests {
    func group(_ name: String, dir: String, tabs: [TabModel]) throws -> GroupModel {
        var group = try JSONDecoder().decode(GroupModel.self, from: Data(
            #"{"id": "\#(UUID().uuidString)", "name": "\#(name)", "colorIndex": 0, "dir": "\#(dir)", "tabs": []}"#.utf8))
        group.tabs = tabs
        return group
    }

    @Test func sparesAndUnnamedSessionsDontOpen() throws {
        func entry(_ json: String) throws -> ClaudeSessionEntry { try JSONDecoder().decode(ClaudeSessionEntry.self, from: Data(json.utf8)) }
        let spare = try entry(#"{"pid": 1, "kind": "bg", "jobId": "7e2dbaf0", "name": "7e2dbaf0", "spare": true}"#)
        let placeholder = try entry(#"{"pid": 2, "kind": "bg", "jobId": "98c044a5", "name": "98c044a5"}"#)
        let named = try entry(#"{"pid": 3, "kind": "bg", "jobId": "dc82e88a", "name": "cold_game_beam_plumbing"}"#)
        #expect(!Store.opensAsTab(spare, isFork: { true }))
        #expect(!Store.opensAsTab(placeholder, isFork: { false }))
        #expect(Store.opensAsTab(placeholder, isFork: { true }))   // a fork opens even before it has a name
        #expect(Store.opensAsTab(named, isFork: { false }))
    }

    @Test func opensBesideTheLastTabUsedInItsFolder() throws {
        let old = TabModel(kind: .claude, cwd: "/w/b"), recent = TabModel(kind: .claude, cwd: "/w/b")
        let other = TabModel(kind: .shell, cwd: "/w/b/sub")
        let groups = [try group("a", dir: "/w/a", tabs: [TabModel(kind: .shell, cwd: "/w/a")]),
                      try group("b", dir: "/w/b", tabs: [old, other, recent])]
        let place = Store.placement(forBackgroundIn: "/w/b", groups: groups,
                                    lastFocusedAt: [old.id: Date(timeIntervalSince1970: 1), recent.id: Date(timeIntervalSince1970: 2)])
        #expect(place?.group == 1 && place?.index == 3)
    }

    @Test func fallsBackToTheGroupWhoseFolderHoldsIt() throws {
        let groups = [try group("w", dir: "/w", tabs: []),
                      try group("b", dir: "/w/b", tabs: [TabModel(kind: .shell, cwd: "/w/b")])]
        let place = Store.placement(forBackgroundIn: "/w/b/deep", groups: groups, lastFocusedAt: [:])
        #expect(place?.group == 1 && place?.index == 1)
        #expect(Store.placement(forBackgroundIn: "/w/bc", groups: [groups[1]], lastFocusedAt: [:]) == nil)
        #expect(Store.placement(forBackgroundIn: "/elsewhere", groups: groups, lastFocusedAt: [:]) == nil)
    }

    @Test func liveBackgroundJobsAreReadFromTheRegistry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = getpid()
        try #"{"pid": \#(me), "sessionId": "s-bg", "kind": "bg", "jobId": "f65bbf83"}"#.write(
            to: dir.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try #"{"pid": \#(me), "sessionId": "s-live", "kind": "interactive"}"#.write(
            to: dir.appendingPathComponent("2.json"), atomically: true, encoding: .utf8)
        try #"{"pid": 999999, "sessionId": "s-dead", "kind": "bg", "jobId": "0a0b0c0d"}"#.write(
            to: dir.appendingPathComponent("3.json"), atomically: true, encoding: .utf8)
        #expect(Store.liveBackgroundJobs(in: dir) == ["s-bg": "f65bbf83"])
    }
}
