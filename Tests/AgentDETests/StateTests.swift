import Foundation
import Testing
@testable import AgentDE

@Suite("Settings decoding")
struct SettingsTests {
    @Test func oneBadValueResetsOnlyItself() throws {
        let saved = #"{"theme": "neon", "fontSize": 15, "sparkles": false}"#
        let settings = AgentDESettings.decodeLenient(from: Data(saved.utf8))
        #expect(Theme.definition(settings.theme).id == "claude")   // unknown theme → the default
        #expect(settings.fontSize == 15)
        #expect(settings.sparkles == false)
        #expect(settings.metalRenderer == false) // missing key → default
    }

    @Test func garbageGivesDefaults() {
        #expect(AgentDESettings.decodeLenient(from: Data("not json".utf8)) == AgentDESettings())
    }
}

/// Loading runs through `Store`, which reads `AGENTDE_STATE` when created, so these run one at a time.
@Suite("Saved state", .serialized)
struct SavedStateTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-state-\(UUID().uuidString)")

    func load(_ json: String) throws -> Store {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        setenv("AGENTDE_STATE", dir.appendingPathComponent("state.json").path, 1)
        setenv("AGENTDE_LOG_DIR", dir.appendingPathComponent("logs").path, 1)
        return Store()
    }

    /// Views ask extensions things from their first frame, which can come before the app finishes launching.
    @Test func extensionsStartWithTheStoreBeforeAnyViewAsks() throws {
        final class Probe: AgentDEExtension {
            let id = "probe", name = "Probe"
            var host: AgentDEHost?
            func start(host: AgentDEHost) { self.host = host }
            func wantsAttention(_ tab: TabInfo) -> Bool { host == nil }   // true only when asked before start
        }
        let probe = Probe()
        AgentDEMain.extensions = [probe]
        defer { AgentDEMain.extensions = [] }
        let store = try load(#"{"groups": [{"id": "\#(UUID().uuidString)", "name": "g", "colorIndex": 0, "dir": "/tmp", "tabs": [{"id": "\#(UUID().uuidString)", "kind": "shell", "cwd": "/tmp"}]}]}"#)
        #expect(probe.host != nil)
        #expect(store.wantsAttention(store.groups[0].tabs[0]) == false)
    }

    @Test func unreadableEntriesAreDroppedOneByOneAndTheOriginalKept() throws {
        let good = UUID().uuidString, tab = UUID().uuidString
        let store = try load("""
        {"groups": [
          {"id": "\(good)", "name": "good", "colorIndex": 1, "dir": "/tmp", "selectedTabID": "\(tab)",
           "tabs": [{"id": "\(tab)", "kind": "shell", "cwd": "/tmp"}, {"id": "\(UUID().uuidString)", "kind": "hologram", "cwd": "/tmp"}]},
          {"id": "\(UUID().uuidString)", "colorIndex": 2, "dir": "/tmp", "tabs": []}
        ], "selectedGroupID": "\(good)", "settings": {"fontSize": 16}}
        """)
        #expect(store.groups.map(\.name) == ["good"])
        #expect(store.groups.first?.tabs.count == 1)
        #expect(store.settings.fontSize == 16)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("state.json.unreadable-") })
    }

    @Test func cleanStateLoadsWithoutABackup() throws {
        let group = UUID().uuidString
        let store = try load(#"{"groups": [{"id": "\#(group)", "name": "repo", "colorIndex": 0, "dir": "/tmp", "tabs": []}], "settings": {}}"#)
        #expect(store.groups.map(\.name) == ["repo"])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.hasPrefix("state.json.unreadable-") })
    }

    @Test func splitsAndShellDrawersFromOlderVersionsStillLoad() throws {
        let group = UUID().uuidString, a = UUID(), b = UUID(), drawer = UUID()
        let store = try load("""
        {"groups": [{"id": "\(group)", "name": "repo", "colorIndex": 0, "dir": "/tmp", "selectedTabID": "\(a.uuidString)",
          "splitPanes": ["\(a.uuidString)", "\(b.uuidString)"],
          "tabs": [{"id": "\(a.uuidString)", "kind": "claude", "cwd": "/tmp", "showShell": true, "companionID": "\(drawer.uuidString)"},
                   {"id": "\(b.uuidString)", "kind": "shell", "cwd": "/tmp"}]}], "settings": {}}
        """)
        #expect(store.groups.first?.tabs.map(\.id) == [a, b])
        #expect(store.groups.first?.selectedTabID == a)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.hasPrefix("state.json.unreadable-") })
    }
}

@Suite("Shell drawers from earlier versions")
struct LegacyDrawerTests {
    func group(_ tabs: [TabModel]) -> GroupModel { GroupModel(name: "g", colorIndex: 0, dir: "/tmp", tabs: tabs) }

    @Test func aDrawerStillRunningBecomesAShellTabBesideItsOwner() {
        let drawer = UUID()
        var owner = TabModel(kind: .claude, cwd: "/w/b")
        owner.companionID = drawer
        owner.showShell = true
        let other = TabModel(kind: .shell, cwd: "/w/b")
        var groups = [group([owner, other])]
        #expect(Store.adoptLegacyDrawers(&groups, running: [drawer]))
        #expect(groups[0].tabs.map(\.id) == [owner.id, drawer, other.id])
        #expect(groups[0].tabs[1].kind == .shell && groups[0].tabs[1].cwd == "/w/b")
        #expect(groups[0].tabs[0].companionID == nil && groups[0].tabs[0].showShell == nil)
        #expect(!Store.adoptLegacyDrawers(&groups, running: [drawer]))   // only once
    }

    @Test func aDrawerWithNothingRunningIsDropped() {
        var owner = TabModel(kind: .claude, cwd: "/tmp")
        owner.companionID = UUID()
        owner.showShell = false
        var groups = [group([owner])]
        #expect(Store.adoptLegacyDrawers(&groups, running: []))
        #expect(groups[0].tabs.map(\.id) == [owner.id])
        #expect(groups[0].tabs[0].companionID == nil)
    }
}

@Suite("Reordering groups")
struct GroupOrderTests {
    struct Item: Identifiable { let id: Int }
    func order(_ id: Int, onto target: Int) -> [Int] {
        Store.moving(id, onto: target, in: (0..<4).map(Item.init)).map(\.id)
    }

    @Test func aGroupDroppedOnAnotherTakesItsPlace() {
        #expect(order(0, onto: 1) == [1, 0, 2, 3])   // down one
        #expect(order(0, onto: 3) == [1, 2, 3, 0])   // to the bottom
        #expect(order(3, onto: 0) == [3, 0, 1, 2])   // to the top
        #expect(order(2, onto: 2) == [0, 1, 2, 3])
        #expect(order(9, onto: 1) == [0, 1, 2, 3])
    }
}

@Suite("Extension data")
struct ExtensionDataTests {
    @Test func olderTabsKeepTheirWorkstreamAndSections() throws {
        let saved = #"{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "kind": "claude", "cwd": "/tmp", "workstreamID": "WS-1", "panelSections": {"memory": false}}"#
        var tab = try JSONDecoder().decode(TabModel.self, from: Data(saved.utf8))
        tab.adoptLegacyWorkstream()
        #expect(tab.extensionData?["workstreams.id"] == "WS-1")
        #expect(tab.extensionData?["workstreams.sections"] == #"{"memory":false}"#)
        #expect(tab.workstreamID == nil && tab.panelSections == nil)
        // A value the extension already set wins over the old field.
        var newer = tab
        newer.workstreamID = "WS-old"
        newer.adoptLegacyWorkstream()
        #expect(newer.extensionData?["workstreams.id"] == "WS-1")
    }
}
