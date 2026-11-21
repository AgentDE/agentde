import AppKit
import Testing
@testable import AgentDE

@Suite("Code in the viewer")
struct CodeTextTests {
    /// Links as agents write them: `path:line`, with a column, or ending a list item's `path:33:`.
    @Test func aLinksLineIsRead() {
        #expect(FileLink.line("src/model_selectors.py:33") == 33)
        #expect(FileLink.line("src/model_selectors.py:33:") == 33)
        #expect(FileLink.line("a.swift:12:5") == 12)
        #expect(FileLink.line("a.swift:12.") == 12)
        #expect(FileLink.line("a.swift") == nil)
        #expect(FileLink.line("a.swift:0") == nil)
        #expect(FileLink.withoutLine("dir/a.py:33") == "dir/a.py")
        #expect(FileLink.withoutLine("dir/a.py:3:7") == "dir/a.py")
    }

    /// A `path:line` link still finds the file.
    @Test func aLinkWithALineResolvesToTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codetext-\(UUID().uuidString)")
        let file = root.appendingPathComponent("handler/model_selectors.py")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Store.resolveFileLink("handler/model_selectors.py:33:", relativeTo: [root.path])?.path == file.standardizedFileURL.path)
    }

    @Test func linesAreFoundByOffset() {
        let text = "one\ntwo\n\nfour\n" as NSString
        let starts = LineIndex.starts(text)
        #expect(starts == [0, 4, 8, 9])
        #expect(LineIndex.line(at: 0, starts: starts) == 1)
        #expect(LineIndex.line(at: 5, starts: starts) == 2)
        #expect(LineIndex.line(at: 9, starts: starts) == 4)
        #expect(text.substring(with: LineIndex.range(ofLine: 2, in: text)) == "two")
        #expect(text.substring(with: LineIndex.range(ofLine: 4, in: text)) == "four")
        #expect(text.substring(with: LineIndex.range(ofLine: 99, in: text)) == "four")
        #expect(LineIndex.range(ofLine: 3, in: text).length == 0)
    }

    private func kinds(_ code: String, _ language: CodeColors.Language) -> [String: CodeColors.Kind] {
        let text = code as NSString
        var out: [String: CodeColors.Kind] = [:]
        for token in CodeColors.tokens(code, language) { out[text.substring(with: token.range)] = token.kind }
        return out
    }

    @Test func pythonIsColored() {
        let found = kinds("def f(x):  # it's a note\n    return \"a # b\" + 'c' + 42\n", CodeColors.hashFamily)
        #expect(found["def"] == .keyword)
        #expect(found["return"] == .keyword)
        #expect(found["# it's a note"] == .comment)
        #expect(found["\"a # b\""] == .string)
        #expect(found["'c'"] == .string)
        #expect(found["42"] == .number)
        #expect(found["f"] == nil && found["x"] == nil)
    }

    @Test func cFamilyCommentsAndStrings() {
        let found = kinds("let url = \"https://a.b\" // see /* not a block\n/* one\ntwo */ var v2 = 3.5", CodeColors.cFamily)
        #expect(found["\"https://a.b\""] == .string)
        #expect(found["// see /* not a block"] == .comment)
        #expect(found["/* one\ntwo */"] == .comment)
        #expect(found["3.5"] == .number)
        #expect(found["v2"] == nil)
        #expect(kinds("a.sorted { $0.edits > $1.edits }", CodeColors.cFamily)["0"] == .number)
        #expect(found["let"] == .keyword && found["var"] == .keyword)
    }

    @Test func sqlKeywordsIgnoreCase() {
        let found = kinds("SELECT id FROM games -- recent\nwhere x = 'it''s'", CodeColors.dashFamily)
        #expect(found["SELECT"] == .keyword && found["FROM"] == .keyword && found["where"] == .keyword)
        #expect(found["-- recent"] == .comment)
    }

    /// An unterminated string or comment ends at the line (or the file), and huge files stay plain.
    @Test func brokenAndHugeFilesAreSafe() {
        #expect(kinds("x = \"open\ny = 1", CodeColors.hashFamily)["\"open"] == .string)
        #expect(!CodeColors.tokens("/* never closed", CodeColors.cFamily).isEmpty)
        #expect(CodeColors.tokens(String(repeating: "x = 1\n", count: 200_000), CodeColors.hashFamily).isEmpty)
    }

    @Test func codeFilesGetNumbersAndProseDoesnt() {
        #expect(ViewerHost.codeLanguage("/r/a/model_selectors.py") != nil)
        #expect(ViewerHost.codeLanguage("/r/Sources/App.swift") != nil)
        #expect(ViewerHost.codeLanguage("/r/Makefile") != nil)
        #expect(ViewerHost.codeLanguage("/r/notes.txt") == nil)
        #expect(ViewerHost.codeLanguage("/r/run.log") == nil)
        #expect(ViewerHost.codeLanguage("/r/data.csv") == nil)
    }

    /// A search that prints more than a pipe holds (64 KB) still finishes; it used to stall into the timeout.
    @Test func longCommandOutputIsReadWhileItRuns() {
        let text = Store.output(of: "/bin/sh", ["-c", "yes /some/long/path/to/a/file.swift | head -n 20000"], timeout: 2)
        #expect(text?.split(separator: "\n").count == 20000)
        #expect(Store.output(of: "/bin/sleep", ["5"], timeout: 0.3) == nil)
    }

    /// Search reads a tab's scrollback again only after it printed something or was resized (#10).
    @Test func scrollbackIsReadOncePerOutput() {
        let id = UUID()
        var reads = 0
        let read = { () -> [String] in reads += 1; return ["line \(reads)"] }
        #expect(ScrollbackCache.lines(id, generation: 1, width: 80, read: read) == ["line 1"])
        #expect(ScrollbackCache.lines(id, generation: 1, width: 80, read: read) == ["line 1"])
        #expect(reads == 1)
        #expect(ScrollbackCache.lines(id, generation: 2, width: 80, read: read) == ["line 2"])
        #expect(ScrollbackCache.lines(id, generation: 2, width: 100, read: read) == ["line 3"])
        ScrollbackCache.forget(keeping: [])
        _ = ScrollbackCache.lines(id, generation: 2, width: 100, read: read)
        #expect(reads == 4)
    }
}
