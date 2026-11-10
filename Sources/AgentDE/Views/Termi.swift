import AppKit
import SwiftUI

/// Termi, AgentDE's mascot, hanging out in the empty end of the tab strip (Settings → Fun). His mood follows
/// the agents: amber and hopping while one waits on you, green and typing while they work, blue and wandering
/// otherwise, asleep after a quiet couple of minutes. Drawn from the same rectangles as the mascot art and
/// animated with Core Animation, so he costs next to nothing while the app is idle. Clicks pass through him.
enum TermiMood: Equatable {
    case needsYou, working, wandering, asleep

    /// Any agent waiting wins, then any working; with nothing going on for `sleepAfter` seconds he sleeps.
    static func of(_ states: [AgentState], quietFor: TimeInterval, sleepAfter: TimeInterval = 120) -> TermiMood {
        if states.contains(.needsYou) { return .needsYou }
        if states.contains(.working) { return .working }
        return quietFor >= sleepAfter ? .asleep : .wandering
    }
}

struct TermiStrip: NSViewRepresentable {
    let mood: TermiMood
    let animated: Bool

    func makeNSView(context: Context) -> TermiView { TermiView() }

    func updateNSView(_ view: TermiView, context: Context) {
        view.animated = animated
        view.update(mood)
    }
}

final class TermiView: NSView {
    private static let unit: CGFloat = 0.17          // points per unit of the 200-unit mascot drawing
    private static let size = CGSize(width: 160 * unit, height: 140 * unit)

    /// Turning animations off (or Reduce Motion on) stops his loops at once; on again, they restart.
    var animated = true { didSet { if animated != oldValue, let shown { draw(shown) } } }
    private var shown: TermiMood?
    private let figure = CALayer()
    private let body = CALayer(), shade = CALayer(), screen = CALayer()
    private var legs: [CALayer] = [], arms: [CALayer] = [], dots: [CALayer] = []
    private let face = CALayer()
    private let extras = CALayer()
    var lastBusy = Date()   // when an agent last worked or waited; tests set it
    private var sleepCheck: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        figure.isGeometryFlipped = true
        figure.bounds = CGRect(origin: .zero, size: Self.size)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ l: CALayer = CALayer()) -> CALayer {
            // Mascot units, offset so the drawing's left edge (x 20) and top (y 36) sit at the figure's corner.
            l.frame = CGRect(x: (x - 20) * Self.unit, y: (y - 36) * Self.unit, width: w * Self.unit, height: h * Self.unit)
            l.cornerRadius = r * Self.unit
            return l
        }
        legs = [rect(68, 146, 20, 28, 4), rect(112, 146, 20, 28, 4)]
        arms = [rect(22, 100, 18, 30, 6), rect(160, 100, 18, 30, 6)]
        _ = rect(36, 44, 128, 110, 14, shade)
        _ = rect(36, 38, 128, 110, 14, body)
        dots = [rect(48, 47, 14, 12, 3), rect(68, 47, 14, 12, 3), rect(88, 47, 14, 12, 3)]
        _ = rect(46, 66, 108, 74, 7, screen)
        face.frame = figure.bounds
        extras.frame = figure.bounds
        for l in legs + arms + [shade, body] + dots + [screen, face, extras] { figure.addSublayer(l) }
        dots.forEach { $0.backgroundColor = NSColor.white.cgColor }
        screen.backgroundColor = NSColor(hex: 0x0E1114).cgColor
        layer?.addSublayer(figure)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never in the way of the tab strip

    override func layout() {
        super.layout()
        // On the strip's floor, at the left of the free space until he walks.
        if figure.animation(forKey: "walk") == nil {
            figure.position = CGPoint(x: min(bounds.width, Self.size.width / 2 + 6), y: Self.size.height / 2 + 4)
        }
        if let mood = shown, mood == .wandering, figure.animation(forKey: "walk") == nil { startWalking() }
    }

    func update(_ mood: TermiMood) {
        if mood == .needsYou || mood == .working { lastBusy = Date() }
        // A quiet spell turns into sleep on its own, without waiting for the next state change.
        var effective = mood
        if mood == .wandering || mood == .asleep {
            effective = Date().timeIntervalSince(lastBusy) >= 120 ? .asleep : .wandering
            sleepCheck?.cancel()
            if effective == .wandering {
                let check = DispatchWorkItem { [weak self] in self?.update(.wandering) }
                sleepCheck = check
                DispatchQueue.main.asyncAfter(deadline: .now() + 121 - Date().timeIntervalSince(lastBusy), execute: check)
            }
        }
        guard effective != shown else { return }
        shown = effective
        draw(effective)
    }

    private func draw(_ mood: TermiMood) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Stop where he is, so a new mood doesn't snap him back to the start.
        if let current = figure.presentation()?.position { figure.position = current }
        figure.removeAllAnimations()
        (legs + arms).forEach { $0.removeAllAnimations() }
        face.sublayers?.forEach { $0.removeFromSuperlayer() }
        extras.sublayers?.forEach { $0.removeFromSuperlayer() }
        figure.opacity = 1

        let (main, dark, glow): (UInt32, UInt32, UInt32) = switch mood {
        case .needsYou: (0xEF9F27, 0xB9700F, 0xFFD089)
        case .working: (0x1D9E75, 0x127256, 0x6FD9B2)
        case .wandering, .asleep: (0x378ADD, 0x215F9F, 0x9CCBF5)
        }
        body.backgroundColor = NSColor(hex: main).cgColor
        (legs + arms + [shade]).forEach { $0.backgroundColor = NSColor(hex: dark).cgColor }
        func pixel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: UInt32, in parent: CALayer? = nil) -> CALayer {
            let l = CALayer()
            l.frame = CGRect(x: (x - 20) * Self.unit, y: (y - 36) * Self.unit, width: w * Self.unit, height: h * Self.unit)
            l.backgroundColor = NSColor(hex: color).cgColor
            (parent ?? face).addSublayer(l)
            return l
        }
        switch mood {
        case .needsYou:   // wide eyes, small open mouth
            for x: CGFloat in [65, 119] { _ = pixel(x, 84, 16, 26, glow); _ = pixel(x + 3, 87, 5, 5, 0xFFFFFF) }
            _ = pixel(93, 122, 14, 7, glow)
        case .working:    // eyes on the work, a small smile
            for x: CGFloat in [65, 119] { _ = pixel(x, 90, 16, 20, glow); _ = pixel(x + 3, 93, 5, 5, 0xFFFFFF) }
            _ = pixel(82, 116, 6, 5, glow); _ = pixel(88, 121, 24, 6, glow); _ = pixel(112, 116, 6, 5, glow)
        case .wandering:  // happy ^ ^ eyes and a smile
            for x: CGFloat in [64, 112] { _ = pixel(x, 97, 8, 6, glow); _ = pixel(x + 8, 92, 8, 6, glow); _ = pixel(x + 16, 97, 8, 6, glow) }
            _ = pixel(82, 114, 6, 5, glow); _ = pixel(88, 119, 24, 6, glow); _ = pixel(112, 114, 6, 5, glow)
        case .asleep:     // closed eyes
            for x: CGFloat in [64, 112] { _ = pixel(x, 100, 24, 5, glow) }
            _ = pixel(92, 120, 16, 4, glow)
        }
        CATransaction.commit()
        guard animated else { return }

        switch mood {
        case .needsYou:
            figure.add(Self.keyframes("transform.translation.y", [0, -5, 0, -2.5, 0], duration: 0.9), forKey: "hop")
            arms[1].add(Self.keyframes("transform.translation.y", [0, -4, 0], duration: 0.6), forKey: "wave")
        case .working:
            // A keyboard on his lap, keys blinking as he types.
            let board = pixel(40, 150, 120, 14, 0x23272E, in: extras)
            board.cornerRadius = 3 * Self.unit
            for (i, x) in [52.0, 76, 100, 124].enumerated() {
                let key = pixel(x, 154, 18, 6, glow, in: extras)
                let blink = Self.keyframes("opacity", [1, 0.25, 1], duration: 0.5)
                blink.beginTime = CACurrentMediaTime() + Double(i) * 0.13
                key.add(blink, forKey: "type")
            }
            for (i, arm) in arms.enumerated() {
                let tap = Self.keyframes("transform.translation.y", [0, 2.5, 0], duration: 0.26)
                tap.beginTime = CACurrentMediaTime() + Double(i) * 0.13
                arm.add(tap, forKey: "type")
            }
        case .wandering:
            startWalking()
        case .asleep:
            figure.opacity = 0.85
            figure.add(Self.keyframes("transform.scale.y", [1, 0.97, 1], duration: 3), forKey: "breathe")
            for i in 0..<3 {
                let z = CATextLayer()
                z.string = "z"
                z.font = NSFont.systemFont(ofSize: 9, weight: .bold)
                z.fontSize = 9
                z.foregroundColor = NSColor(hex: 0x9CCBF5).cgColor
                z.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                z.frame = CGRect(x: Self.size.width - 6, y: -4, width: 10, height: 12)
                z.opacity = 0
                let rise = CAAnimationGroup()
                rise.animations = [Self.keyframes("transform.translation.y", [0, -10], duration: 2.4),
                                   Self.keyframes("transform.translation.x", [0, 5], duration: 2.4),
                                   Self.keyframes("opacity", [0, 1, 0], duration: 2.4)]
                rise.duration = 2.4
                rise.repeatCount = .infinity
                rise.beginTime = CACurrentMediaTime() + Double(i) * 0.8
                z.add(rise, forKey: "rise")
                extras.addSublayer(z)
            }
        }
    }

    /// Back and forth along the free end of the strip, legs stepping, about 14 points a second.
    private func startWalking() {
        guard animated, shown == .wandering else { return }
        let margin = Self.size.width / 2 + 6
        let room = bounds.width - 2 * margin
        guard room > 20 else { return }
        let walk = CABasicAnimation(keyPath: "position.x")
        walk.fromValue = margin
        walk.toValue = margin + room
        walk.duration = Double(room) / 14
        walk.autoreverses = true
        walk.repeatCount = .infinity
        walk.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        figure.add(walk, forKey: "walk")
        for (i, leg) in legs.enumerated() {
            let step = Self.keyframes("transform.translation.y", [0, -2, 0], duration: 0.5)
            step.beginTime = CACurrentMediaTime() + Double(i) * 0.25
            leg.add(step, forKey: "step")
        }
    }

    private static func keyframes(_ keyPath: String, _ values: [CGFloat], duration: CFTimeInterval) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = duration
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }
}
