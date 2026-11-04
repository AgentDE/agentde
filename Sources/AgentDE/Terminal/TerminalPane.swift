import AppKit
import SwiftTerm
import SwiftUI

/// Hosts a tab's long-lived terminal view inside SwiftUI without ever recreating it.
struct TerminalPane: NSViewRepresentable {
    let tab: TabModel
    let store: Store

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer()
        container.wantsLayer = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        let session = store.terminals.session(for: tab)
        let view = session.view
        // A reused container may still hold another tab's terminal, which would cover this one.
        for other in container.subviews where other !== view { other.removeFromSuperview() }
        if view.superview !== container {
            view.removeFromSuperview()
            view.autoresizingMask = []
            container.addSubview(view)   // TerminalContainer sizes it
        }
        session.startIfNeeded(tab)
        if store.activeTab?.id == tab.id, !store.paletteOpen, store.renamingTabID == nil, store.renamingGroupID == nil {
            DispatchQueue.main.async {
                // Only claim focus when no terminal or text field has it.
                if let window = view.window, window.firstResponder !== view, !(window.firstResponder is NSTextView),
                   !(window.firstResponder is TerminalView) {
                    window.makeFirstResponder(view)
                }
            }
        }
    }
}

/// Keeps its terminal view exactly its own size, on every layout and whenever the view's frame changes.
/// Autoresizing alone only adds size changes to whatever frame the view had, so a frame set at the wrong moment
/// (say, as the viewer opened and the terminal moved into a new pane) stayed wrong: the terminal reported more
/// rows than showed, and the shell's bottom lines (Claude's input box) ran under the status bar.
final class TerminalContainer: NSView {
    private var observers: [NSObjectProtocol] = []

    override func layout() {
        super.layout()
        fit()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fit()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: subview,
                                                                queue: nil) { [weak self] _ in self?.fit() })
        fit()
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Sets each subview's frame to the bounds when it differs; logs a correction bigger than a point.
    func fit() {
        for view in subviews where view.frame != bounds {
            if abs(view.frame.height - bounds.height) > 1 || abs(view.frame.width - bounds.width) > 1, bounds.height > 0 {
                DebugLog.log("terminal frame \(Int(view.frame.width))×\(Int(view.frame.height)) refit to \(Int(bounds.width))×\(Int(bounds.height))", "tab")
            }
            view.frame = bounds
        }
    }
}
