import AppKit
@testable import AgentDE
import SwiftUI
import Testing

/// The viewer's header must never be wider than its pane: a long name used to push the whole column (viewer, chat
/// and status bar) past the window's right edge.
@Suite("Viewer header", .serialized)
@MainActor
struct ViewerHeaderTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-viewer-\(UUID().uuidString)")

    func store() throws -> Store {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"groups":[]}"#.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        setenv("AGENTDE_STATE", dir.appendingPathComponent("state.json").path, 1)
        setenv("AGENTDE_LOG_DIR", dir.appendingPathComponent("logs").path, 1)
        return Store()
    }

    func width<V: View>(_ view: V, store: Store, proposed: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: view.environment(store))
        return host.sizeThatFits(in: CGSize(width: proposed, height: 30)).width
    }

    @Test func aLongNameFitsANarrowPane() throws {
        let store = try store()
        let long = "/tmp/" + String(repeating: "a-very-long-report-name-", count: 8) + "final.md"
        var tab = TabModel(kind: .shell, cwd: "/tmp")
        tab.viewerItem = long
        tab.viewerHistory = [long, "/tmp/other.md"]
        for pane in [420.0, 700.0] {
            let header = width(ViewerHeader(tab: tab, item: long), store: store, proposed: pane)
            #expect(header <= pane, "header \(header) pt in a \(pane) pt pane")
        }
    }

    @Test func aShortNameDoesNotStretch() throws {
        let store = try store()
        var tab = TabModel(kind: .shell, cwd: "/tmp")
        tab.viewerHistory = ["/tmp/a.md", "/tmp/b.md"]
        let menu = width(ViewerHistoryMenu(tab: tab) { Text("a.md") }, store: store, proposed: 600)
        #expect(menu < 120, "menu \(menu) pt for a 4-letter name")
    }
}
