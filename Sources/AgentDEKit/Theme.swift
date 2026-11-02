import AppKit
import SwiftUI

extension Color {
    public init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    public convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.fallback
}

extension EnvironmentValues {
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Every color the app paints, resolved for one theme in one light/dark mode.
public struct Theme {
    public var window: Color
    public var sidebar: Color
    public var text: Color
    public var secondary: Color
    public var muted: Color
    public var border: Color
    public var hover: Color
    public var selected: Color
    public var terminalBackground: NSColor
    public var terminalForeground: NSColor
    public var terminalSelection: NSColor
    /// High-contrast themes outline the active tab, row and pane instead of relying on subtle fills.
    public var outline: Color? = nil

    public static let working = Color(hex: 0x1D9E75)
    public static let needsYou = Color(hex: 0xEF9F27)
    public static let doneUnseen = Color(hex: 0x378ADD)

    public init(window: Color, sidebar: Color, text: Color, secondary: Color, muted: Color, border: Color, hover: Color,
                selected: Color, terminalBackground: NSColor, terminalForeground: NSColor, terminalSelection: NSColor,
                outline: Color? = nil) {
        self.window = window
        self.sidebar = sidebar
        self.text = text
        self.secondary = secondary
        self.muted = muted
        self.border = border
        self.hover = hover
        self.selected = selected
        self.terminalBackground = terminalBackground
        self.terminalForeground = terminalForeground
        self.terminalSelection = terminalSelection
        self.outline = outline
    }

    /// Claude's dark theme, until the app sets the real one.
    public static let fallback = Theme(
        window: Color(hex: 0x262624), sidebar: Color(hex: 0x1F1E1D), text: Color(hex: 0xF5F4EE),
        secondary: Color(hex: 0xB7B5A9), muted: Color(hex: 0x85837A), border: Color.white.opacity(0.09),
        hover: Color.white.opacity(0.05), selected: Color.white.opacity(0.09),
        terminalBackground: NSColor(hex: 0x262624), terminalForeground: NSColor(hex: 0xE8E6DC),
        terminalSelection: NSColor(hex: 0x4A4840))
}
