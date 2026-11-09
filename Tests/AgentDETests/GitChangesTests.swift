import Foundation
import Testing
@testable import AgentDE

@Suite("Changes tab")
struct GitChangesTests {
    private func data(_ parts: [String]) -> Data { Data(parts.joined(separator: "\0").utf8 + [0]) }

    @Test func statusAndCountsCombine() {
        let status = data([" M Sources/App.swift", "A  docs/new file.md", "?? notes.txt", " D old.txt",
                           "R  Sources/Renamed.swift", "Sources/Original.swift", "UU conflict.swift"])
        let numstat = data(["3\t1\tSources/App.swift", "10\t0\tdocs/new file.md", "0\t4\told.txt",
                            "2\t2\t", "Sources/Original.swift", "Sources/Renamed.swift", "-\t-\timage.png"])
        let changes = GitChanges.parse(status: status, numstat: numstat)
        #expect(changes.map(\.path) == ["conflict.swift", "docs/new file.md", "notes.txt", "old.txt",
                                        "Sources/App.swift", "Sources/Renamed.swift"])
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        #expect(byPath["Sources/App.swift"] == GitChange(path: "Sources/App.swift", status: "M", added: 3, removed: 1))
        #expect(byPath["docs/new file.md"]?.status == "A")
        #expect(byPath["notes.txt"]?.status == "??")
        #expect(byPath["notes.txt"]?.added == nil)
        #expect(byPath["old.txt"]?.status == "D")
        #expect(byPath["Sources/Renamed.swift"]?.status == "R")
        #expect(byPath["Sources/Renamed.swift"]?.added == 2)
        #expect(byPath["conflict.swift"]?.status == "U")
    }

    @Test func emptyRepositoryHasNoChanges() {
        #expect(GitChanges.parse(status: Data(), numstat: Data()).isEmpty)
    }

    @Test func logRecordsParse() {
        let log = Data("abc123\u{1f}Fix the thing\u{1f}Sam\u{1f}1700000000\0\ndef456\u{1f}Subject with \u{1f}\u{1f}x\u{1f}bad\0".utf8)
        let commits = GitChanges.parseLog(log)
        #expect(commits == [GitCommit(hash: "abc123", subject: "Fix the thing", author: "Sam", date: Date(timeIntervalSince1970: 1_700_000_000))])
    }

    /// A real repository: an edit, a new file and a commit show up, and an untracked file's diff is the whole file.
    @Test func readsARealRepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func sh(_ args: [String]) throws {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", dir.path, "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try task.run()
            task.waitUntilExit()
        }
        try sh(["init", "-q"])
        try "one\ntwo\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try sh(["add", "a.txt"])
        try sh(["commit", "-q", "-m", "First"])
        try "one\n2\nthree\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let result = try #require(GitChanges.load(in: dir.path))
        #expect(result.changes.map(\.path) == ["a.txt", "b.txt"])
        #expect(result.changes[0].added == 2 && result.changes[0].removed == 1)
        #expect(result.log.map(\.subject) == ["First"])
        #expect(GitChanges.diff(result.changes[1], root: result.root).contains("+new"))
        #expect(GitChanges.show(result.log[0], root: result.root).contains("+one"))
        #expect(GitChanges.load(in: FileManager.default.temporaryDirectory.path)?.root == nil)
    }
}
