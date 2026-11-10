import AppKit
import QuartzCore
import SwiftUI

/// A soft amber ring around a tab's status: its workstream has an open ask. The agent isn't stopped, so this
/// is quieter than the needs-you dot (no pulse, no dock badge, no notification).
public struct AskRing: View {
    public var size: CGFloat = 13
    public init(size: CGFloat = 13) { self.size = size }

    public var body: some View {
        Circle().stroke(Theme.needsYou.opacity(0.85), lineWidth: 1.3).frame(width: size, height: size).allowsHitTesting(false)
    }
}

/// The tab status dot. Animations run as Core Animation layers in the render server, so they cost no app CPU.
public struct StatusDot: NSViewRepresentable {
    public let state: AgentState
    public var animated = true
    public var size: CGFloat = 7
    public init(state: AgentState, animated: Bool = true, size: CGFloat = 7) { self.state = state; self.animated = animated; self.size = size }

    public func makeNSView(context: Context) -> DotView {
        let view = DotView()
        view.configure(state: state, animated: animated, size: size)
        return view
    }

    public func updateNSView(_ view: DotView, context: Context) {
        view.configure(state: state, animated: animated, size: size)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? {
        CGSize(width: size + 6, height: size + 6)
    }

    public final class DotView: NSView {
        private let dot = CALayer()
        private let ring = CALayer()
        private var current: (AgentState, Bool, CGFloat)?

        public override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(ring)
            layer?.addSublayer(dot)
        }

        required init?(coder: NSCoder) { fatalError() }

        public override func layout() {
            super.layout()
            guard let current else { return }
            place(size: current.2)
        }

        private func place(size: CGFloat) {
            let frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = frame
            dot.cornerRadius = size / 2
            ring.frame = frame
            ring.cornerRadius = size / 2
            CATransaction.commit()
        }

        public func configure(state: AgentState, animated: Bool, size: CGFloat) {
            if let current, current.0 == state, current.1 == animated, current.2 == size { return }
            current = (state, animated, size)
            setAccessibilityElement(state != .none)
            setAccessibilityRole(.image)
            let label: String = switch state {
            case .working: "Working"
            case .needsYou: "Needs you"
            case .doneUnseen: "Done"
            case .none: ""
            }
            setAccessibilityLabel(label)
            dot.removeAllAnimations()
            ring.removeAllAnimations()
            ring.opacity = 0
            dot.opacity = 1
            dot.transform = CATransform3DIdentity
            place(size: size)
            switch state {
            case .none:
                dot.backgroundColor = NSColor.clear.cgColor
                dot.borderWidth = 0
            case .working:
                dot.backgroundColor = NSColor(Theme.working).cgColor
                if animated { dot.add(breathe(), forKey: "breathe") }
            case .needsYou:
                dot.backgroundColor = NSColor(Theme.needsYou).cgColor
                ring.backgroundColor = NSColor(Theme.needsYou).cgColor
                if animated { ring.add(pulse(), forKey: "pulse") }
            case .doneUnseen:
                dot.backgroundColor = NSColor(Theme.doneUnseen).cgColor
            }
        }

        private func breathe() -> CAAnimation {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.35
            opacity.toValue = 1
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.78
            scale.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [opacity, scale]
            group.duration = 1.2
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return group
        }

        private func pulse() -> CAAnimation {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.6
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.55
            opacity.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 1.5
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            return group
        }
    }
}

extension View {
    /// Draws the theme's high-contrast outline around an active element. A no-op in other themes.
    public func activeOutline(_ active: Bool, radius: CGFloat, dashed: Bool = false) -> some View {
        modifier(ActiveOutline(active: active, radius: radius, dashed: dashed))
    }
}

private struct ActiveOutline: ViewModifier {
    public let active: Bool
    public let radius: CGFloat
    public let dashed: Bool
    @Environment(\.theme) private var theme

    public func body(content: Content) -> some View {
        content.overlay {
            if active, let outline = theme.outline {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(outline, style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : []))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Small icon button used in the header and tab strip.
public struct IconButton: View {
    public let symbol: String
    public let help: String
    public var active = false
    public let action: () -> Void
    public init(symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.active = active; self.action = action
    }
    @Environment(\.theme) private var theme
    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(active ? theme.text : theme.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering || active ? theme.selected : .clear))
                .activeOutline(active, radius: 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(help)
        .onHover { hovering = $0 }
    }
}

/// A small icon-and-word button, for actions whose icons alone would be ambiguous.
public struct LabeledButton: View {
    public let title: String
    public let symbol: String
    public let help: String
    public let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false
    public init(title: String, symbol: String, help: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.help = help; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(hovering ? theme.text : theme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.selected : theme.hover))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(help)
        .onHover { hovering = $0 }
    }
}
