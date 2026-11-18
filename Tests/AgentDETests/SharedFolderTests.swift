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

    /// Jump to finds a session that ran in a worktree or subfolder, under the deepest group that holds it.
    @Test func jumpToFindsSessionsInsideAGroupsFolder() {
        let repo = GroupModel(name: "repo", colorIndex: 0, dir: "/r")
        let docs = GroupModel(name: "docs", colorIndex: 1, dir: "/r/docs")
        let twin = GroupModel(name: "repo 2", colorIndex: 2, dir: "/r/")
        let groups = [repo, docs, twin]
        let all = [RecentSession(sessionId: "wt", name: "in shorts", cwd: "/r/.claude/worktrees/x", lastActive: Date()),
                   RecentSession(sessionId: "d", name: "guide", cwd: "/r/docs/api", lastActive: Date()),
                   RecentSession(sessionId: "near", name: "lookalike", cwd: "/rx", lastActive: Date()),
                   RecentSession(sessionId: "top", name: "root", cwd: "/r", lastActive: Date())]
        #expect(Store.searchable(all, for: repo, in: groups, open: []).map(\.sessionId) == ["wt", "top"])
        #expect(Store.searchable(all, for: docs, in: groups, open: []).map(\.sessionId) == ["d"])
        #expect(Store.searchable(all, for: twin, in: groups, open: []).isEmpty)   // the first group with the folder has them
        #expect(Store.searchable(all, for: repo, in: groups, open: ["wt"]).map(\.sessionId) == ["top"])
        var pinning = repo
        pinning.pinnedSessions = [all[0]]
        #expect(Store.searchable(all, for: repo, in: [pinning, docs, twin], open: []).map(\.sessionId) == ["top"])
    }
}

@Suite("Resume cover")
struct ResumeCoverTests {
    /// Off once the input line shows and output settles; never before output, never past the limit.
    @Test func comesOffWhenTheConversationIsDrawn() {
        #expect(!ResumeCover.done(elapsed: 1, quietFor: nil, promptOnScreen: false))              // nothing drawn yet
        #expect(!ResumeCover.done(elapsed: 3, quietFor: 2, promptOnScreen: false))                // the shell, waiting on the agent
        #expect(!ResumeCover.done(elapsed: 3, quietFor: 0.1, promptOnScreen: true))               // still drawing
        #expect(ResumeCover.done(elapsed: 3, quietFor: 0.5, promptOnScreen: true))
        #expect(!ResumeCover.done(elapsed: 1, quietFor: 1, promptOnScreen: nil))                  // no known input line: wait a bit
        #expect(ResumeCover.done(elapsed: 2.5, quietFor: 1, promptOnScreen: nil))
        #expect(ResumeCover.done(elapsed: ResumeCover.limit, quietFor: nil, promptOnScreen: false)) // a failed resume
    }
}
