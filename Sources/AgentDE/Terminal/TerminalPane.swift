import AppKit
import SwiftTerm
import SwiftUI

/// Hosts a tab's long-lived terminal view inside SwiftUI without ever recreating it.
struct TerminalPane: NSViewRepresentable {
    let tab: TabModel
    let store: Store

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
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
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
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
