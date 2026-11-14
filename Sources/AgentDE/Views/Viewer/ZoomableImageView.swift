import AppKit

/// An image in the viewer that fits by default and zooms: pinch, ⌘+ / ⌘− / ⌘0 (after clicking into it), or
/// double-click to switch between fitting and actual size. Zoomed in, it scrolls and drags like a document.
final class ZoomableImageView: NSScrollView {
    private let imageView = NSImageView()
    /// While true the image follows the view's size; any zoom turns it off until ⌘0 or a double-click.
    private var fitting = true

    static let maxMagnification: CGFloat = 8

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        allowsMagnification = true
        maxMagnification = Self.maxMagnification
        imageView.imageScaling = .scaleAxesIndependently
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(userZoomed), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `image`. A new image (or a reload of a fitted one) fits; a reload while zoomed keeps the zoom.
    func show(_ image: NSImage?, keepZoom: Bool) {
        // Actual size is one image pixel per screen pixel. An image's own size follows its dpi stamp, so a
        // 600-dpi export of 3120 px would count as 374 points and fit at that, soft and small.
        if let image, let pixels = Self.pixelSize(of: image) {
            image.size = Self.displaySize(pixels: pixels, scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        if !keepZoom { fitting = true }
        if fitting { fit() }
    }

    /// The largest bitmap's pixel dimensions, or nil for an image with none (a PDF or vector image).
    static func pixelSize(of image: NSImage) -> NSSize? {
        let reps = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
        guard let rep = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Points that show `pixels` one to one on a screen with this backing scale.
    static func displaySize(pixels: NSSize, scale: CGFloat) -> NSSize {
        let scale = max(scale, 1)
        return NSSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    /// The magnification that fits the whole image in view, never enlarging a small one past actual size.
    static func fitMagnification(image: NSSize, in view: NSSize) -> CGFloat {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return 1 }
        return min(1, view.width / image.width, view.height / image.height)
    }

    private func fit() {
        let fit = Self.fitMagnification(image: imageView.frame.size, in: contentSize)
        minMagnification = min(fit, 1) * 0.5
        magnification = fit
    }

    override func layout() {
        super.layout()
        if fitting { fit() }
    }

    @objc private func userZoomed() { fitting = false }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            if fitting {
                fitting = false
                let point = contentView.convert(event.locationInWindow, from: nil)
                setMagnification(1, centeredAt: point)
            } else {
                fitting = true
                fit()
            }
            return
        }
        super.mouseDown(with: event)
    }

    /// ⌘+ / ⌘− / ⌘0 while the image has focus. These are also menu shortcuts (Bigger Text, Smaller Text, Toggle
    /// Sidebar); AppKit offers key equivalents to the key window's views before the menu, so the image takes them
    /// only while it's the first responder and the menu keeps them everywhere else.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command,
              let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "=", "+": zoom(by: 1.25)
        case "-": zoom(by: 1 / 1.25)
        case "0": fitting = true; fit()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func zoom(by factor: CGFloat) {
        fitting = false
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: center)
    }
}

/// Keeps a document smaller than the view centered instead of pinned to the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
