import AppKit
import SwiftUI

extension View {
    /// A quick hover label for icons and other terse controls: it appears under the pointer after a short
    /// pause (immediately when moving from one hinted control to the next), and hides on click, typing,
    /// scrolling or leaving. Also the control's accessibility hint.
    public func hint(_ text: String) -> some View {
        modifier(HoverHint(text: text))
    }
}

private struct HoverHint: ViewModifier {
    public let text: String
    @State private var token = UUID()

    public func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onHover { inside in
                if inside { HintPanel.shared.schedule(text, owner: token) } else { HintPanel.shared.cancel(owner: token) }
            }
            .onDisappear { HintPanel.shared.cancel(owner: token) }
    }
}

/// The one floating window that shows hints. It ignores the mouse, never takes focus, and sits above the
/// app's windows, so a hint is never clipped by the tab strip or sidebar it belongs to.
@MainActor
public final class HintPanel {
    public static let shared = HintPanel()

    private let delay: TimeInterval = 0.35
    /// Within this long after a hint hides, the next one shows without the pause.
    private let warm: TimeInterval = 0.6
    private var panel: NSPanel?
    private var label: NSTextField?
    private var pending: DispatchWorkItem?
    private var owner: UUID?
    private var hiddenAt = Date.distantPast
    private var monitor: Any?

    public func schedule(_ text: String, owner: UUID) {
        pending?.cancel()
        self.owner = owner
        let showsNow = panel?.isVisible == true || Date().timeIntervalSince(hiddenAt) < warm
        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (showsNow ? 0.02 : delay), execute: work)
    }

    public func cancel(owner: UUID) {
        guard self.owner == owner else { return }
        hide()
    }

    private func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            hiddenAt = Date()
        }
    }

    private func show(_ text: String) {
        guard NSApp.isActive, !text.isEmpty else { return }
        let (panel, label) = makePanel()
        label.stringValue = text
        let size = label.fittingSize
        let padded = NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
        // Under the pointer, kept on the pointer's screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .infinite
        var origin = NSPoint(x: mouse.x - padded.width / 2, y: mouse.y - 22 - padded.height)
        if origin.y < screen.minY { origin.y = mouse.y + 14 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - padded.width - 4)
        panel.setFrame(NSRect(origin: origin, size: padded), display: true)
        label.frame = NSRect(x: 8, y: 4, width: padded.width - 16, height: padded.height - 8)
        panel.orderFrontRegardless()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                self?.hide()
                return event
            }
        }
    }

    private func makePanel() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        panel.contentView = background
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 320
        background.addSubview(label)
        self.panel = panel
        self.label = label
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HintPanel.shared.hide() }
        }
        return (panel, label)
    }
}
