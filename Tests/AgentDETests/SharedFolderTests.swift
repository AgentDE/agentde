import Foundation
import Testing
@testable import AgentDE

@Suite("Shared folders")
struct SharedFolderTests {
    /// A second group in the same folder lists none of its sessions: they belong to the first.
    @Test func aFoldersSessionsBelongToItsFirstGroup() {
        let first = GroupModel(name: "app", colorIndex: 0, dir: "/r")
        let second = GroupModel(name: "app 2", colorIndex: 1, dir: "/r/")
        let other = GroupModel(name: "web", colorIndex: 2, dir: "/w")
        let groups = [first, other, second]
        let all = [RecentSession(sessionId: "a", name: "fix login", cwd: "/r", lastActive: Date()),
                   RecentSession(sessionId: "b", name: "landing", cwd: "/w", lastActive: Date())]
        #expect(Store.sessions(all, for: first, in: groups, open: []).map(\.sessionId) == ["a"])
        #expect(Store.sessions(all, for: second, in: groups, open: []).isEmpty)
        #expect(Store.sessions(all, for: other, in: groups, open: []).map(\.sessionId) == ["b"])
        #expect(Store.sessions(all, for: first, in: groups, open: ["a"]).isEmpty)
    }
}
