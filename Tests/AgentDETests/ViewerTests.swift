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
        #expect(ViewerKind.of("/a/clip.mov") == .other)
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
}

@Suite("Tabs and workstreams")
struct TabWorkstreamTests {
    @Test func newTabsGetAWorkstreamAndOldOnesLoadWithout() throws {
        #expect(TabModel(kind: .claude, cwd: "/tmp").extensionData == nil)   // the extension gives it one
        let old = try JSONDecoder().decode(TabModel.self, from: Data(#"{"id": "\#(UUID().uuidString)", "kind": "claude", "cwd": "/tmp"}"#.utf8))
        #expect(old.workstreamID == nil)
        #expect(old.viewerItem == nil && old.panelWidth == nil)
    }
}
