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
        // SwiftUI can update a pane once more after its tab is closed. Starting it then would bring the
        // closed tab's holder back (and re-attach its background agent), so a tab no longer in the store gets nothing.
        guard store.tab(tab.id) != nil else {
            for other in container.subviews { other.removeFromSuperview() }
            return
        }
        let session = store.terminals.session(for: tab)
        let view = session.view
        // A reused container may still hold another tab's terminal, which would cover this one.
        for other in container.subviews where other !== view { other.removeFromSuperview() }
        guard let owned = container as? TerminalContainer, owned.show(tab.id, terminal: view) else { return }
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
///
/// It also keeps a tab's terminal on screen whatever order SwiftUI builds and tears down panes in (a split, the
/// viewer opening): the newest container showing a tab holds its terminal, one being replaced can't take it back,
/// and a container leaving the window hands the terminal to another one still showing that tab.
final class TerminalContainer: NSView {
    private var observers: [NSObjectProtocol] = []
    private(set) var tabID: UUID?
    private weak var terminal: NSView?
    /// Larger for the container that started showing its tab more recently.
    private var serial = 0
    private static var nextSerial = 0
    private static let live = NSHashTable<TerminalContainer>.weakObjects()

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        Self.live.add(self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `tab`'s terminal here unless a newer container on screen has it. Returns whether it's here.
    @discardableResult func show(_ tab: UUID, terminal: NSView) -> Bool {
        if tabID != tab {
            tabID = tab
            Self.nextSerial += 1
            serial = Self.nextSerial
        }
        self.terminal = terminal
        if terminal.superview !== self, mayTake(terminal) { adopt(terminal) }
        return terminal.superview === self
    }

    /// From a container on screen, only a newer one takes it; otherwise (held off screen, or not at all) anyone.
    private func mayTake(_ terminal: NSView) -> Bool {
        guard let holder = terminal.superview as? TerminalContainer, holder !== self, holder.window != nil else { return true }
        return serial > holder.serial
    }

    private func adopt(_ terminal: NSView) {
        terminal.removeFromSuperview()
        terminal.autoresizingMask = []
        addSubview(terminal)   // sized by `fit`
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let terminal, let tabID else { return }
        if window != nil {
            if terminal.superview !== self, mayTake(terminal) { adopt(terminal) }
        } else if terminal.superview === self {
            // Leaving with the terminal: the newest other container still showing this tab gets it.
            let heir = Self.live.allObjects
                .filter { $0 !== self && $0.tabID == tabID && $0.window != nil }
                .max { $0.serial < $1.serial }
            heir?.adopt(terminal)
        }
    }

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
