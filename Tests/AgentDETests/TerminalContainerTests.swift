import AppKit
import Testing
@testable import AgentDE

@Suite("Terminal pane")
struct TerminalContainerTests {
    /// However the terminal's frame drifts, the pane puts it back to exactly its own size, so the terminal never
    /// has rows that hang below what shows.
    @Test @MainActor func theTerminalAlwaysFillsItsPaneExactly() {
        let pane = TerminalContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))   // a stale, taller frame
        pane.addSubview(terminal)
        #expect(terminal.frame == pane.bounds)

        pane.setFrameSize(NSSize(width: 800, height: 350))   // the viewer opened above it
        #expect(terminal.frame == pane.bounds)

        terminal.setFrameSize(NSSize(width: 800, height: 420))   // something resized the terminal itself
        #expect(terminal.frame.size == NSSize(width: 800, height: 350))

        terminal.removeFromSuperview()
        terminal.setFrameSize(NSSize(width: 10, height: 10))   // no longer the pane's to fix
        #expect(terminal.frame.size == NSSize(width: 10, height: 10))
    }
}
