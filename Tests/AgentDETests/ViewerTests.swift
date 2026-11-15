import Foundation
import Testing
@testable import AgentDE

@Suite("Links and the viewer")
struct ViewerRoutingTests {
    @Test(arguments: [
        ("https://github.com/acme/app/pull/10479", "web"),
        ("http://localhost:5173/dash", "local"),
        ("http://127.0.0.1:8000", "local"),
        ("http://app.localhost:3000/x", "local"),
        ("main4/REPORT.md", "file"),
        ("/Users/me/plot.png", "file"),
        ("file:///tmp/a.md", "file"),
        ("~/notes.md:12", "file"),
        ("https://claude.ai/artifact/SAiZc8wc4HG3hh98xzBxUx", "artifact"),
        ("https://pages.example.com/a/report.html", "artifact"),   // an extension's link rule
        ("https://example.com/pages/x/1", "web"),
    ])
    func classifiesLinks(_ link: String, _ expected: String) {
        ViewerLinks.rules = [ViewerLinks.claude, LinkRule(pattern: #"https://pages\.example\.com/a/[\w.-]+"#, marker: "pages.example.com/a/")]
        let kind: String
        switch LinkTarget.classify(link) {
        case .web: kind = "web"
        case .localWeb: kind = "local"
        case .file: kind = "file"
        case .artifact: kind = "artifact"
        }
        #expect(kind == expected)
    }

    @Test func picksHowToShowAnItem() {
        #expect(ViewerKind.of("/a/REPORT.md") == .markdown)
        #expect(ViewerKind.of("/a/report.html") == .html)
        #expect(ViewerKind.of("http://localhost:5173") == .web)
        #expect(ViewerKind.of("/a/paper.pdf") == .pdf)
        #expect(ViewerKind.of("/a/plot.PNG") == .image)
        #expect(ViewerKind.of("/a/change.diff") == .diff)
        #expect(ViewerKind.of("/a/train.py") == .text)
        #expect(ViewerKind.of("/a/Makefile") == .text)
        #expect(ViewerKind.of("/a/clip.mov") == .media)
        #expect(ViewerKind.of("/a/trailer.mp4") == .media)
        #expect(ViewerKind.of("/a/song.mp3") == .media)
        #expect(ViewerKind.of("/a/model.usdz") == .other)
        // Raw mode shows Markdown as its text, and changes nothing else.
        #expect(ViewerKind.shown("/a/REPORT.md", raw: true) == .text)
        #expect(ViewerKind.shown("/a/REPORT.md", raw: false) == .markdown)
        #expect(ViewerKind.shown("/a/report.html", raw: true) == .html)
    }

    @Test func colorsDiffLines() {
        let styled = ViewerHost.styled("@@ -1 +1 @@\n-old\n+new\n same", diff: true, theme: Theme.resolve("midnight", dark: true))
        #expect(styled.string == "@@ -1 +1 @@\n-old\n+new\n same\n")
        let added = styled.attribute(.backgroundColor, at: (styled.string as NSString).range(of: "+new").location, effectiveRange: nil)
        #expect(added != nil)
    }
}

@Suite("Viewer history")
struct ViewerHistoryTests {
    /// Two links to one page that the menu would show alike keep only the newest; a different file with the
    /// same name in another folder stays.
    @Test func sameLabelCountsOnce() {
        let older = "https://example.com/view?key=artifacts/by/me/deck.html"
        let newer = "/Users/x/a/deck.md"
        var history = ViewerHistory.recording(older, in: nil)
        history = ViewerHistory.recording(newer, in: history)
        history = ViewerHistory.recording("/Users/x/b/deck.md", in: history)
        #expect(history == ["/Users/x/b/deck.md", newer, older])
        #expect(ViewerHistory.distinct(["/a/x.md", "/a/x.md", "/b/x.md"]) == ["/a/x.md", "/b/x.md"])
        let alike = ["https://example.com/p", "https://example.com/p?ref=1"]   // both read "example.com/p"
        #expect(ViewerHistory.distinct(alike) == ["https://example.com/p"])
    }

    /// Each open counts; past the cap, the least opened go first.
    @Test func viewerOpensAreCounted() {
        var counts = ViewerOpens.counting("/a.md", in: [:])
        counts = ViewerOpens.counting("/a.md", in: counts)
        counts = ViewerOpens.counting("https://x.com/p", in: counts)
        #expect(counts == ["/a.md": 2, "https://x.com/p": 1])
        var full = Dictionary(uniqueKeysWithValues: (0..<ViewerOpens.limit).map { ("/f\($0)", 2) })
        full = ViewerOpens.counting("/new", in: full)
        #expect(full.count == ViewerOpens.limit && full["/new"] == nil)   // one open doesn't beat the others' two
    }

    /// Web pages and files look different in the menu, local pages included.
    @Test func iconsTellPagesFromFiles() {
        #expect(ViewerHistory.symbol("https://example.com/report.html") == "globe")
        #expect(ViewerHistory.symbol("/Users/x/report.html") == "doc")
        #expect(ViewerHistory.symbol("/Users/x/notes.md") == "doc.text")
        #expect(ViewerHistory.symbol(FileManager.default.temporaryDirectory.path) == "folder")   // a folder shown in the viewer
    }

    @Test func reopeningMovesAnItemToTheFrontAndTheListStaysShort() {
        var history: [String]? = nil
        for item in ["/a.md", "/b.md", "/c.html", "/a.md"] { history = ViewerHistory.recording(item, in: history) }
        #expect(history == ["/a.md", "/c.html", "/b.md"])
        for n in 0..<20 { history = ViewerHistory.recording("/f\(n)", in: history) }
        #expect(history?.count == ViewerHistory.limit && history?.first == "/f19")
    }

    @Test func backAndForwardWalkTheListAndStopAtItsEnds() {
        let history = ["/c", "/b", "/a"]   // newest first
        #expect(ViewerHistory.step(from: "/c", in: history, by: 1) == "/b")
        #expect(ViewerHistory.step(from: "/b", in: history, by: 1) == "/a")
        #expect(ViewerHistory.step(from: "/a", in: history, by: 1) == nil)
        #expect(ViewerHistory.step(from: "/b", in: history, by: -1) == "/c")
        #expect(ViewerHistory.step(from: "/c", in: history, by: -1) == nil)
        // With the viewer closed, back reopens the newest; forward does nothing.
        #expect(ViewerHistory.step(from: nil, in: history, by: 1) == "/c")
        #expect(ViewerHistory.step(from: nil, in: history, by: -1) == nil)
        #expect(ViewerHistory.step(from: nil, in: nil, by: 1) == nil)
    }

    /// As in a browser: back from /c to /b, then a link to /d drops /c.
    @Test func followingALinkAfterGoingBackDropsWhatWasAhead() {
        #expect(ViewerHistory.following("/d", from: "/b", in: ["/c", "/b", "/a"]) == ["/d", "/b", "/a"])
        #expect(ViewerHistory.following("/d", from: "/c", in: ["/c", "/b", "/a"]) == ["/d", "/c", "/b", "/a"])
        #expect(ViewerHistory.following("/d", from: nil, in: nil) == ["/d"])
    }
}

@Suite("Tabs and workstreams")
struct TabWorkstreamTests {
    @Test func newTabsGetAWorkstreamAndOldOnesLoadWithout() throws {
        #expect(TabModel.agent("claude", cwd: "/tmp").extensionData == nil)   // the extension gives it one
        let old = try JSONDecoder().decode(TabModel.self, from: Data(#"{"id": "\#(UUID().uuidString)", "kind": "claude", "cwd": "/tmp"}"#.utf8).migratedTab())
        #expect(old.workstreamID == nil)
        #expect(old.viewerItem == nil && old.panelWidth == nil)
    }
}

@Suite("Image zoom")
struct ImageZoomTests {
    @Test func fittingNeverEnlargesAndShrinksToTheTighterSide() {
        #expect(ZoomableImageView.fitMagnification(image: NSSize(width: 200, height: 100), in: NSSize(width: 800, height: 600)) == 1)
        #expect(ZoomableImageView.fitMagnification(image: NSSize(width: 1600, height: 800), in: NSSize(width: 800, height: 600)) == 0.5)
        #expect(ZoomableImageView.fitMagnification(image: NSSize(width: 800, height: 1200), in: NSSize(width: 800, height: 600)) == 0.5)
        #expect(ZoomableImageView.fitMagnification(image: .zero, in: NSSize(width: 800, height: 600)) == 1)
    }
}
