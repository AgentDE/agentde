import AppKit

/// Termi beside a notification banner (Settings → Fun): a small borderless panel at the top-right of the main
/// screen, just left of where macOS shows banners. Amber with a "?" when an agent needs you, blue with a thumbs
/// up when one is done. He leaves after a few seconds, or as soon as that tab is seen; a click on him goes to
/// the tab. Nothing is drawn while he's away: the panel is ordered out and its animations removed.
final class TermiPopup {
    static let size = CGSize(width: 104, height: 84)
    /// About where macOS puts a banner (not public API): its width and its gap from the screen's right edge.
    static let bannerWidth: CGFloat = 344, bannerMargin: CGFloat = 16, gap: CGFloat = 4
    /// How long he stays: a question waits longer than a finish.
    static func stay(_ kind: Notifier.Kind) -> TimeInterval { kind == .needsYou ? 12 : 6 }

    private let onClick: (UUID?) -> Void
    private var panel: NSPanel?
    private var view: TermiPopupView?
    private(set) var tab: UUID?
    private var hideWork: DispatchWorkItem?

    init(onClick: @escaping (UUID?) -> Void) { self.onClick = onClick }

    /// Top-right of the screen's usable area, left of the banner column.
    static func frame(visible: CGRect) -> CGRect {
        CGRect(x: visible.maxX - bannerMargin - bannerWidth - gap - size.width, y: visible.maxY - size.height,
               width: size.width, height: size.height)
    }

    func show(_ kind: Notifier.Kind, tab: UUID, animated: Bool) {
        guard let screen = NSScreen.screens.first else { return }   // the menu bar's screen, where banners appear
        let (panel, view) = self.panel.flatMap { p in self.view.map { (p, $0) } } ?? make()
        self.tab = tab
        view.show(kind, animated: animated)
        panel.setFrame(Self.frame(visible: screen.visibleFrame), display: true)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = animated ? 0.2 : 0; panel.animator().alphaValue = 1 }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stay(kind), execute: work)
    }

    /// Hides him; with a tab, only if he's there for that tab.
    func hide(tab: UUID? = nil) {
        guard let panel, panel.isVisible, tab == nil || tab == self.tab else { return }
        hideWork?.cancel()
        self.tab = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) { [weak self] in
            guard self?.tab == nil else { return }   // shown again meanwhile
            panel.orderOut(nil)
            self?.view?.stop()
        }
    }

    private func make() -> (NSPanel, TermiPopupView) {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let view = TermiPopupView(frame: CGRect(origin: .zero, size: Self.size))
        view.onClick = { [weak self] in
            let tab = self?.tab
            self?.hide()
            self?.onClick(tab)
        }
        panel.contentView = view
        self.panel = panel
        self.view = view
        return (panel, view)
    }
}

/// Termi at the right (next to the banner), with a "?" bubble over his shoulder when an agent needs you.
final class TermiPopupView: NSView {
    var onClick: () -> Void = {}
    let termi = TermiView(unit: 0.36)
    private let bubble = CALayer()
    private let mark = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let w = termi.size.width + 12, h = termi.size.height + 16
        termi.frame = CGRect(x: frame.width - w, y: 4, width: w, height: h)
        addSubview(termi)
        bubble.frame = CGRect(x: termi.frame.minX - 6, y: frame.height - 30, width: 24, height: 22)
        bubble.backgroundColor = NSColor.white.cgColor
        bubble.borderColor = NSColor(hex: 0x1B1F27).cgColor
        bubble.borderWidth = 1.5
        bubble.cornerRadius = 7
        mark.string = "?"
        mark.font = NSFont.systemFont(ofSize: 15, weight: .heavy)
        mark.fontSize = 15
        mark.alignmentMode = .center
        mark.foregroundColor = NSColor(hex: 0x1B1F27).cgColor
        mark.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        mark.frame = CGRect(x: 0, y: 1, width: 24, height: 19)
        bubble.addSublayer(mark)
        layer?.addSublayer(bubble)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ kind: Notifier.Kind, animated: Bool) {
        termi.animated = animated
        termi.update(kind == .needsYou ? .needsYou : .done)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.isHidden = kind != .needsYou
        CATransaction.commit()
    }

    /// No animation keeps running while he's away.
    func stop() { termi.animated = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
