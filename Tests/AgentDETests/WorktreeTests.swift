import Foundation
import Testing
@testable import AgentDE

@Suite("New workstream worktrees")
struct WorktreeTests {
    @Test func namesMustWorkAsBranchesAndFolders() {
        #expect(Worktrees.validName("  cold-match ") == "cold-match")
        #expect(Worktrees.validName("v0.8_taxo") == "v0.8_taxo")
        for bad in ["", "-x", ".x", "a b", "a/b", "a..b", "x.lock", "x.", "x;rm", String(repeating: "a", count: 61)] {
            #expect(Worktrees.validName(bad) == nil, "\(bad)")
        }
    }

    @Test func worktreesSitBesideTheRepo() {
        #expect(Worktrees.path(repoRoot: "/Users/a/git/app", name: "cold-match") == "/Users/a/git/app-worktrees/cold-match")
        #expect(Worktrees.path(repoRoot: "/Users/a/git/app/", name: "x") == "/Users/a/git/app-worktrees/x")
    }

    @discardableResult
    private static func git(_ repo: URL, _ args: [String]) throws -> String {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo/sub"), withIntermediateDirectories: true)
        try git(base.appendingPathComponent("repo"), ["init", "-q"])
        try git(base.appendingPathComponent("repo"), ["commit", "-q", "--allow-empty", "-m", "start"])
        return base
    }

    @Test func withoutARemoteItBranchesFromWhatsCheckedOut() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        let root = try #require(Worktrees.repoRoot(of: repo.appendingPathComponent("sub").path))
        #expect(URL(fileURLWithPath: root).resolvingSymlinksInPath().path == repo.path)
        #expect(try Worktrees.add(repoRoot: root, name: "cold-match").get() == "HEAD")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("repo-worktrees/cold-match/.git").path))
        // The branch exists now, so a second one fails with git's message.
        guard case .failure(let error) = Worktrees.add(repoRoot: root, name: "cold-match") else { Issue.record("made it twice"); return }
        #expect(!error.message.isEmpty)
        #expect(Worktrees.repoRoot(of: base.path) == nil)
    }

    @Test func branchesFromTheRemotesFreshlyFetchedDefaultBranch() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        // The team's default branch is dev; the clone knows that, but the team has moved on since it fetched.
        let team = base.appendingPathComponent("team")
        try FileManager.default.createDirectory(at: team, withIntermediateDirectories: true)
        try Self.git(team, ["init", "-q", "-b", "dev"])
        try Self.git(team, ["commit", "-q", "--allow-empty", "-m", "first"])
        try Self.git(repo, ["remote", "add", "origin", team.path])
        try Self.git(repo, ["fetch", "-q", "origin"])
        try Self.git(repo, ["remote", "set-head", "origin", "-a"])
        try Self.git(team, ["commit", "-q", "--allow-empty", "-m", "dev work"])
        let devTip = try Self.git(team, ["rev-parse", "HEAD"])
        #expect(Worktrees.baseBranch(repoRoot: repo.path) == "origin/dev")

        #expect(try Worktrees.add(repoRoot: repo.path, name: "cold-match").get() == "origin/dev")
        let worktree = base.appendingPathComponent("repo-worktrees/cold-match")
        #expect(try Self.git(worktree, ["rev-parse", "HEAD"]) == devTip)
        #expect(try Self.git(worktree, ["rev-parse", "--abbrev-ref", "HEAD"]) == "cold-match")
        #expect(try Self.git(worktree, ["config", "--get", "branch.cold-match.merge"]).isEmpty)   // doesn't track dev
    }
}
