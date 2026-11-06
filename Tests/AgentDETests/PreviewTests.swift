import Foundation
import Testing
@testable import AgentDE

@Suite("Markdown preview")
struct MarkdownTests {
    @Test func blocks() {
        let html = MarkdownRenderer.html("""
        # Content strategy

        A paragraph with **bold**, *italic*, `code` and a [link](https://example.com).

        - "Category" replaces "play style"
        - Beyond content
          - recommendations
        1. first
        2. second

        > a quote

        | Area | Change |
        |---|---|
        | toys | to define |

        ```swift
        let x = 1 < 2
        ```
        """)
        #expect(html.contains("<h1>Content strategy</h1>"))
        #expect(html.contains("<strong>bold</strong>") && html.contains("<em>italic</em>") && html.contains("<code>code</code>"))
        #expect(html.contains("<a href=\"https://example.com\">link</a>"))
        #expect(html.contains("<ul>") && html.contains("<li>&quot;Category&quot; replaces &quot;play style&quot;"))
        #expect(html.contains("<li>recommendations"))
        #expect(html.contains("<ol>") && html.contains("<li>second"))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<th>Area</th>") && html.contains("<td>to define</td>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"))
    }

    @Test func snakeCaseIsNotItalic() {
        #expect(MarkdownRenderer.inline("cold_budget_modeling") == "cold_budget_modeling")
    }

    @Test func htmlIsEscaped() {
        #expect(MarkdownRenderer.html("<script>alert(1)</script>").contains("&lt;script&gt;"))
    }
}

@Suite("File explorer")
struct FileExplorerTests {
    /// Dotfiles always show; the eye button adds generated folders like `.git`.
    @Test func showsDotfilesAndHidesGeneratedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-explorer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in [".git", ".claude", "src"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let model = FileExplorerModel(root: root.path, selection: nil)
        #expect(model.rows.map(\.node.name) == [".claude", "src", ".env"])
        model.showHidden = true
        #expect(model.rows.map(\.node.name) == [".claude", ".git", "src", ".env"])
    }
}

@Suite("File links")
struct FileLinkTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-links-\(UUID().uuidString)")

    func makeFile(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    @Test func resolvesRelativeToTheTabsFolder() throws {
        let doc = try makeFile("content-strategy/content-strategy.md")
        #expect(Store.resolveFileLink("content-strategy/content-strategy.md", relativeTo: ["/nowhere", root.path]) == doc)
    }

    /// `Files are in /…/renders/thumb/:` — a folder, which opens a File Explorer tab.
    @Test func resolvesFoldersEndingASentence() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("renders/thumb/a.png")
        let folder = file.deletingLastPathComponent()
        let found = Store.resolveFileLink(folder.path + "/:", relativeTo: [])
        #expect(found?.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(found.map { Store.isFolder($0.path) } == true && !Store.isFolder(file.path))
    }

    @Test func handlesFileURLsAndLineNumbers() throws {
        let file = try makeFile("src/main.swift")
        #expect(Store.resolveFileLink(file.absoluteString, relativeTo: []) == file)
        #expect(Store.resolveFileLink("src/main.swift:42:7", relativeTo: [root.path]) == file)
        #expect(Store.resolveFileLink("src/missing.swift", relativeTo: [root.path]) == nil)
    }

    /// The terminal ends a link at a space: `Claude outputs/rendered_thumbs/compare.html` arrives without `Claude `.
    @Test func findsPathsCutAtASpace() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try makeFile("Claude outputs/rendered_thumbs/compare.html")
        #expect(Store.resolveFileLink("outputs/rendered_thumbs/compare.html", relativeTo: ["/nowhere", root.path]) == page)
        let report = try makeFile("my report.html")
        #expect(Store.resolveFileLink("report.html", relativeTo: [root.path]) == report)
        #expect(Store.resolveFileLink("outputs/rendered_thumbs/missing.html", relativeTo: [root.path]) == nil)
        #expect(Store.resolveFileLink("thumbs/compare.html", relativeTo: [root.path]) == nil)   // not a name's ending
    }

    /// A path that ends a sentence: `All four models are in Claude outputs/3d_bakeoff/compare.html.`
    @Test func ignoresPunctuationAfterAPath() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try makeFile("Claude outputs/3d_bakeoff/compare.html")
        #expect(Store.resolveFileLink("outputs/3d_bakeoff/compare.html.", relativeTo: [root.path]) == page)
        #expect(Store.resolveFileLink("Claude outputs/3d_bakeoff/compare.html),", relativeTo: [root.path]) == page)
        let artifact = try makeFile("artifacts/orders.html")
        #expect(Store.resolveFileLink("/artifacts/orders.html.", relativeTo: [root.path]) == artifact)
        #expect(Store.resolveFileLink("outputs/3d_bakeoff/missing.html.", relativeTo: [root.path]) == nil)
    }

    /// Written relative to some subfolder, or just a file name: found by searching the folders.
    @Test func searchesForPathsFromASubfolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feet = try makeFile("Claude outputs/stomp_everything/shots/round8d/feet_options.png")
        let smoke = try makeFile("Claude outputs/stomp_everything/shots/round8d/smoke_options.png")
        let saved = Store.fileSearch
        defer { Store.fileSearch = saved }
        Store.fileSearch = { name, folder in   // what Spotlight would answer, without waiting for it to index
            ((FileManager.default.enumerator(atPath: folder)?.allObjects as? [String]) ?? [])
                .filter { ($0 as NSString).lastPathComponent == name }.map { (folder as NSString).appendingPathComponent($0) }
        }
        #expect(Store.resolveFileLink("stomp_everything/shots/round8d/feet_options.png", relativeTo: [root.path]) == feet)
        #expect(Store.resolveFileLink("smoke_options.png.", relativeTo: [root.path]) == smoke)
        #expect(Store.resolveFileLink("round8d/missing.png", relativeTo: [root.path]) == nil)
        #expect(Store.resolveFileLink("other/feet_options.png", relativeTo: [root.path]) == nil)   // the path must match
    }
}
