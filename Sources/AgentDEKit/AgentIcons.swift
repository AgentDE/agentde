import AppKit
import SwiftUI

/// Icons for agents and tabs: SF Symbol names, plus a few drawn here (`claude`, a pixel critter). Drawn ones are
/// template images, so they tint like symbols.
public enum AgentIcons {
    /// Claude's: a small pixel critter.
    public static let claude = "agentde.claude"

    /// The icon as a template image `size` points across, for layers and menus.
    public static func image(_ name: String, size: CGFloat) -> NSImage? {
        if name == claude { return pixels(critter, size: size) }
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .medium)
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        symbol?.isTemplate = true
        return symbol
    }

    /// Body, two eyes (gaps), arms out to the sides, four legs.
    static let critter = [
        ".XXXXXXXX.",
        ".X.XXXX.X.",
        ".X.XXXX.X.",
        "XXXXXXXXXX",
        ".XXXXXXXX.",
        ".X.X..X.X.",
    ]

    static func pixels(_ rows: [String], size: CGFloat) -> NSImage {
        let columns = rows.map(\.count).max() ?? 1
        let cell = size / CGFloat(max(columns, rows.count))
        let width = cell * CGFloat(columns), height = cell * CGFloat(rows.count)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            NSColor.black.setFill()
            let origin = CGPoint(x: (size - width) / 2, y: (size - height) / 2)
            // One path for every cell, filled once, so neighbors don't leave anti-aliased seams between them.
            let path = NSBezierPath()
            path.windingRule = .nonZero
            for (r, row) in rows.enumerated() {
                for (c, char) in row.enumerated() where char == "X" {
                    path.appendRect(NSRect(x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(r) * cell, width: cell, height: cell)
                        .insetBy(dx: -0.01, dy: -0.01))
                }
            }
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

public extension Image {
    /// An agent or tab icon by name: an SF Symbol, or one `AgentIcons` draws.
    static func icon(_ name: String, size: CGFloat = 14) -> Image {
        if name == AgentIcons.claude, let image = AgentIcons.image(name, size: size) {
            return Image(nsImage: image).renderingMode(.template)
        }
        return Image(systemName: name)
    }
}

/// A tab's icon in its state's color: green and breathing while the agent works, amber and pulsing while it needs
/// you, blue when it finished unseen, `idle` otherwise. The loops are Core Animation, like `StatusDot`'s.
public struct StatusIcon: NSViewRepresentable {
    public let name: String
    public let state: AgentState
    public var idle: NSColor
    public var animated = true
    public var size: CGFloat = 12

    public init(name: String, state: AgentState, idle: NSColor, animated: Bool = true, size: CGFloat = 12) {
        self.name = name
        self.state = state
        self.idle = idle
        self.animated = animated
        self.size = size
    }

    public func makeNSView(context: Context) -> IconView { IconView() }

    public func updateNSView(_ view: IconView, context: Context) {
        view.configure(name: name, state: state, idle: idle, animated: animated, size: size)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: IconView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    public final class IconView: NSView {
        private let tint = CALayer()
        private let mask = CALayer()
        private var current: (String, AgentState, NSColor, Bool, CGFloat)?

        public override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            tint.mask = mask
            layer?.addSublayer(tint)
        }

        required init?(coder: NSCoder) { fatalError() }

        public override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tint.frame = bounds
            mask.frame = tint.bounds
            CATransaction.commit()
        }

        public override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            mask.contentsScale = window?.backingScaleFactor ?? 2
        }

        func configure(name: String, state: AgentState, idle: NSColor, animated: Bool, size: CGFloat) {
            if let current, current.0 == name, current.1 == state, current.2 == idle, current.3 == animated, current.4 == size { return }
            let imageChanged = current?.0 != name || current?.4 != size
            current = (name, state, idle, animated, size)
            if imageChanged, let image = AgentIcons.image(name, size: size) {
                var rect = NSRect(origin: .zero, size: NSSize(width: size, height: size))
                mask.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                mask.contentsGravity = .resizeAspect
                mask.contentsScale = window?.backingScaleFactor ?? 2
            }
            setAccessibilityElement(state != .none)
            setAccessibilityRole(.image)
            let label: String = switch state {
            case .working: "Working"
            case .needsYou: "Needs you"
            case .doneUnseen: "Done"
            case .none: ""
            }
            setAccessibilityLabel(label)
            tint.removeAllAnimations()
            tint.opacity = 1
            let color: NSColor = switch state {
            case .working: NSColor(Theme.working)
            case .needsYou: NSColor(Theme.needsYou)
            case .doneUnseen: NSColor(Theme.doneUnseen)
            case .none: idle
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tint.backgroundColor = color.cgColor
            CATransaction.commit()
            guard animated else { return }
            if state == .working { tint.add(fade(from: 0.4, duration: 1.2), forKey: "breathe") }
            if state == .needsYou { tint.add(fade(from: 0.35, duration: 0.6), forKey: "pulse") }
        }

        private func fade(from low: Float, duration: CFTimeInterval) -> CAAnimation {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = low
            opacity.toValue = 1
            opacity.duration = duration
            opacity.autoreverses = true
            opacity.repeatCount = .infinity
            opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return opacity
        }
    }
}
