import Foundation
import Testing
@testable import AgentDE

@Suite("Pinned sessions")
struct PinnedSessionTests {
    let a = RecentSession(sessionId: "a", name: "fix login", cwd: "/r", lastActive: Date(timeIntervalSince1970: 1))
    let b = RecentSession(sessionId: "b", name: "release notes", cwd: "/r", lastActive: Date(timeIntervalSince1970: 2))

    @Test func pinningAddsToTheTopAndPinningAgainRemoves() {
        let one = Store.togglingPin(a, in: [])
        let two = Store.togglingPin(b, in: one)
        #expect(two.map(\.sessionId) == ["b", "a"])
        #expect(Store.togglingPin(a, in: two).map(\.sessionId) == ["b"])
    }

    /// Groups saved before pinning load without it, and pinned sessions survive a save and load.
    @Test func pinnedSessionsAreSavedWithTheGroup() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"g","colorIndex":0,"dir":"/r","tabs":[]}"#
        let group = try JSONDecoder().decode(GroupModel.self, from: Data(old.utf8))
        #expect(group.pinnedSessions == nil)
        var pinned = group
        pinned.pinnedSessions = [b, a]
        let back = try JSONDecoder().decode(GroupModel.self, from: JSONEncoder().encode(pinned))
        #expect(back.pinnedSessions == [b, a])
    }
}
