import AppKit
import Foundation
import Testing
@testable import AgentDE

/// A tab's terminal stays on screen whatever order SwiftUI makes, updates and removes the panes showing it.
@Suite("Terminal handoff") @MainActor
struct TerminalHandoffTests {
    let tab = UUID()
    let terminal = NSView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                          backing: .buffered, defer: true)

    func onScreen(_ container: TerminalContainer) { window.contentView?.addSubview(container) }

    /// A pane replaced by a new one (a split appearing) updates once more on its way out: it can't take the
    /// terminal back, and when it leaves, the new pane still has it.
    @Test func replacedPaneCantTakeItBack() {
        let old = TerminalContainer(); onScreen(old)
        #expect(old.show(tab, terminal: terminal))
        let new = TerminalContainer()
        #expect(new.show(tab, terminal: terminal))   // made before it's on screen
        onScreen(new)
        #expect(!old.show(tab, terminal: terminal))  // the late update
        old.removeFromSuperview()
        #expect(terminal.superview === new)
    }

    /// The pane holding the terminal leaves first (the browser pane closing, say): the pane that stays gets it.
    @Test func leavingPaneHandsItOn() {
        let stays = TerminalContainer(); onScreen(stays)
        stays.show(tab, terminal: terminal)
        let goes = TerminalContainer(); onScreen(goes)
        #expect(goes.show(tab, terminal: terminal))
        goes.removeFromSuperview()
        #expect(terminal.superview === stays)
    }

    /// A pane that comes on screen while the terminal isn't on screen anywhere takes it.
    @Test func paneOnScreenTakesAnOrphan() {
        let gone = TerminalContainer()
        gone.show(tab, terminal: terminal)   // never on screen
        let shown = TerminalContainer()
        shown.show(tab, terminal: terminal)
        onScreen(shown)
        #expect(terminal.superview === shown)
        #expect(!gone.show(tab, terminal: terminal))   // older, and the holder is on screen
    }
}
