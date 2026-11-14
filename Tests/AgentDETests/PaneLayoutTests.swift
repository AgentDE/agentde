import Foundation
import Testing
@testable import AgentDE

@Suite("Split layouts")
struct PaneLayoutTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func splittingNestsAndReads() {
        let two = PaneLayout.tab(a).splitting(a, with: b, vertical: false)
        #expect(two.tabs == [a, b])
        let three = two.splitting(b, with: c, vertical: true)
        #expect(three.tabs == [a, b, c])
        guard case .split(false, _, .tab(a), .split(true, _, .tab(b), .tab(c))) = three else {
            Issue.record("unexpected shape \(three)"); return
        }
    }

    @Test func removingLetsTheSiblingTakeTheSpace() {
        let three = PaneLayout.tab(a).splitting(a, with: b, vertical: false).splitting(b, with: c, vertical: true)
        #expect(three.removing(b)?.tabs == [a, c])
        #expect(PaneLayout.tab(a).removing(a) == nil)
    }

    @Test func replacingAndRatios() {
        let two = PaneLayout.tab(a).splitting(a, with: b, vertical: false)
        #expect(two.replacing(b, with: c).tabs == [a, c])
        guard case .split(_, let ratio, _, _) = two.settingRatio(0.95, at: []) else { Issue.record("no split"); return }
        #expect(ratio == 0.85)   // clamped so no pane disappears
    }

    /// Closed tabs drop out; fewer than two left means no split.
    @Test func pruningClosedTabs() {
        let three = PaneLayout.tab(a).splitting(a, with: b, vertical: false).splitting(b, with: c, vertical: true)
        #expect(three.pruned(to: [a, c])?.tabs == [a, c])
        #expect(three.pruned(to: [a]) == nil)
    }

    /// Saved layouts load back the same.
    @Test func roundTripsThroughJSON() throws {
        let layout = PaneLayout.tab(a).splitting(a, with: b, vertical: false).splitting(b, with: c, vertical: true)
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: data) == layout)
    }
}
