import Testing
@testable import AgentDE

@Suite("Header folder label")
struct HeaderBarTests {
    @Test func showsTheGroupFolderAndTheTabsWhenDifferent() {
        #expect(HeaderBar.folderLabel(group: "/u/app", tab: "/u/app") == "app")
        #expect(HeaderBar.folderLabel(group: "/u/app", tab: "/u/app/") == "app")
        #expect(HeaderBar.folderLabel(group: "/u/app", tab: "/u/app/.claude/worktrees/ql-crash") == "app › ql-crash")
        #expect(HeaderBar.folderLabel(group: "/u/app", tab: "/tmp/other") == "app › other")
    }
}
