import AppKit
@testable import AgentDE
import Testing

/// Editing text files in the viewer: what loads as editable, and how a change on disk meets your edits.
@Suite("Editing text in the viewer", .serialized)
@MainActor
struct TextEditingTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-edit-\(UUID().uuidString)")
    let theme = Theme.resolve("midnight", dark: true)

    func file(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func onDiskChange() {
        #expect(TextEdits.onDiskChange(disk: "a", saved: "a", shown: "ab") == .keep)       // nothing new on disk
        #expect(TextEdits.onDiskChange(disk: "ab", saved: "a", shown: "ab") == .keep)      // already showing it
        #expect(TextEdits.onDiskChange(disk: "agent", saved: "a", shown: "a") == .reload)  // no edits of yours
        #expect(TextEdits.onDiskChange(disk: "agent", saved: "a", shown: "mine") == .conflict)
    }

    /// Only a whole UTF-8 file can be edited: a truncated or binary one would be saved wrong.
    @Test func onlyWholeUTF8IsEditable() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ViewerHost.readTextFile(try file("a.txt", Data("héllo\n".utf8))) == ("héllo\n", true))
        #expect(ViewerHost.readTextFile(try file("b.bin", Data([0xFF, 0xFE, 0x00]))).whole == false)
        #expect(ViewerHost.readTextFile(try file("c.log", Data(repeating: 65, count: 2_000_001))).whole == false)
    }

    /// Your edits are written in place; a file that changed under them isn't overwritten.
    @Test func savesEditsButNotOverAnotherChange() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try file("notes.txt", Data("one\n".utf8))
        let host = ViewerHost(tabID: UUID())
        host.show(url.path, theme: theme)
        let text = try #require((host.subviews.first as? NSScrollView)?.documentView as? NSTextView)
        #expect(text.isEditable)
        text.string = "one\ntwo\n"
        host.saveEdits()
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
        // An agent writes the file, then you save edits made to the old text: the agent's stays.
        try "agent\n".write(to: url, atomically: false, encoding: .utf8)
        text.string = "one\ntwo\nthree\n"
        host.saveEdits()
        #expect(try String(contentsOf: url, encoding: .utf8) == "agent\n")
    }

    @Test func diffsStayReadOnly() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try file("change.diff", Data("+a\n".utf8))
        let host = ViewerHost(tabID: UUID())
        host.show(url.path, theme: theme)
        let text = try #require((host.subviews.first as? NSScrollView)?.documentView as? NSTextView)
        #expect(!text.isEditable)
    }
}
