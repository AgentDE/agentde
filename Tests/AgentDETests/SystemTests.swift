import Foundation
import Testing
@testable import AgentDE

@Suite("Git branch")
struct GitInfoTests {
    func repo(head: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try head.write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func readsTheBranchFromSubfolders() throws {
        let dir = try repo(head: "ref: refs/heads/me/feed-autoplay\n")
        let sub = dir.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(GitInfo.branch(at: sub.path) == "me/feed-autoplay")
    }

    @Test func followsWorktreePointers() throws {
        let main = try repo(head: "ref: refs/heads/dev\n")
        let worktreeGitDir = main.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feature\n".write(to: worktreeGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGitDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(GitInfo.branch(at: worktree.path) == "feature")
    }

    @Test func detachedHeadShowsTheShortCommit() throws {
        let dir = try repo(head: "0123456789abcdef0123456789abcdef01234567\n")
        #expect(GitInfo.branch(at: dir.path) == "01234567")
    }
}


@Suite("Process tree")
struct ProcessTreeTests {
    @Test func findsGrandchildren() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 & wait"]
        try shell.run()
        defer { shell.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let descendants = ProcessTree.terminalDescendants(of: shell.processIdentifier)
        #expect(!descendants.isEmpty)
        for pid in descendants { kill(pid, SIGKILL) }
    }

    /// shell(1) on tty 7 → claude(2) → tool(3); claude also started a detached daemon(4, no tty) whose
    /// background session(5) has its own tty 9.
    @Test func endsOnlyWhatIsOnTheTabsTerminal() {
        let tree: [pid_t: ProcessTree.Info] = [
            1: .init(parent: 0, terminal: 7), 2: .init(parent: 1, terminal: 7), 3: .init(parent: 2, terminal: 7),
            4: .init(parent: 2, terminal: -1), 5: .init(parent: 4, terminal: 9),
        ]
        #expect(ProcessTree.descendants(of: 1, in: tree) == [3, 2])
    }
}

@Suite("Reaping")
struct ReapingTests {
    @Test func anExitedChildIsAZombieUntilReaped() throws {
        var pid: pid_t = 0
        // posix_spawn directly, so Foundation's own reaping doesn't race the check.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { free(argv[0]) }
        #expect(posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil) == 0)
        var waited = 0
        while !ProcessTree.isZombie(pid), waited < 50 { usleep(20_000); waited += 1 }
        #expect(ProcessTree.isZombie(pid))
        #expect(waitpid(pid, nil, WNOHANG) == pid)
        #expect(!ProcessTree.isZombie(pid))
    }
}

@Suite("Session registry")
struct SessionRegistryTests {
    @Test func decodesOnlyFilesThatChanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("1.json"), b = dir.appendingPathComponent("2.json")
        try #"{"pid": 1, "sessionId": "a", "status": "idle"}"#.write(to: a, atomically: true, encoding: .utf8)
        try #"{"pid": 2, "sessionId": "b"}"#.write(to: b, atomically: true, encoding: .utf8)
        let reader = SessionRegistryReader(dir: dir)
        #expect(reader.read().count == 2)
        #expect(reader.decodes == 2)
        #expect(reader.read().count == 2)
        #expect(reader.decodes == 2)                       // nothing changed, nothing decoded
        try #"{"pid": 1, "sessionId": "a", "status": "busy"}"#.write(to: a, atomically: true, encoding: .utf8)
        #expect(reader.read().first { $0.sessionId == "a" }?.status == "busy")
        #expect(reader.decodes == 3)
        try FileManager.default.removeItem(at: b)
        #expect(reader.read().map(\.sessionId) == ["a"])
    }

    /// A name Claude made from the folder ("my-repo-25") isn't a name: tabs keep the session's own title.
    @Test func aDerivedNameIsNotAName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"pid": 1, "sessionId": "a", "name": "my-repo-25", "nameSource": "derived"}"#
            .write(to: dir.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try #"{"pid": 2, "sessionId": "b", "name": "fix_login", "nameSource": "user"}"#
            .write(to: dir.appendingPathComponent("2.json"), atomically: true, encoding: .utf8)
        let entries = SessionRegistryReader(dir: dir).read()
        let a = entries.first { $0.sessionId == "a" }, b = entries.first { $0.sessionId == "b" }
        #expect(a?.name == nil && a?.derivedName == "my-repo-25")
        #expect(b?.name == "fix_login" && b?.derivedName == nil)
    }
}
