import AppKit
import SwiftUI

enum GroupPalette {
    static let builtIn = [
        PaletteDefinition(id: "soft", name: "Soft", colors: [0x7F77DD, 0x1D9E75, 0xD85A30, 0x378ADD, 0xD4537E, 0xBA7517, 0x639922, 0x888780]),
        PaletteDefinition(id: "vivid", name: "Vivid", colors: [0x8B5CF6, 0x10B981, 0xF97316, 0x3B82F6, 0xEC4899, 0xEAB308, 0x22C55E, 0x94A3B8]),
        PaletteDefinition(id: "pastel", name: "Pastel", colors: [0xAFA9EC, 0x5DCAA5, 0xF0997B, 0x85B7EB, 0xED93B1, 0xEF9F27, 0x97C459, 0xB4B2A9]),
    ]
    /// Built-in palettes, then extensions' (set at launch).
    static var all = builtIn

    static func hexes(_ name: String) -> [UInt32] {
        let colors = (all.first { $0.id == name } ?? builtIn[0]).colors
        return colors.isEmpty ? builtIn[0].colors : colors
    }

    static func color(_ index: Int, _ name: String) -> Color {
        let list = hexes(name)
        return Color(hex: list[((index % list.count) + list.count) % list.count])
    }

    static let names = ["Violet", "Teal", "Coral", "Blue", "Pink", "Amber", "Green", "Stone"]
}

extension Theme {
    static let builtIn: [ThemeDefinition] = [
        ThemeDefinition(id: "claude", name: "Claude (warm)") { dark in
            dark ? Theme(window: Color(hex: 0x262624), sidebar: Color(hex: 0x1F1E1D), text: Color(hex: 0xF5F4EE),
                         secondary: Color(hex: 0xB7B5A9), muted: Color(hex: 0x85837A), border: Color.white.opacity(0.09),
                         hover: Color.white.opacity(0.05), selected: Color.white.opacity(0.09),
                         terminalBackground: NSColor(hex: 0x262624), terminalForeground: NSColor(hex: 0xE8E6DC),
                         terminalSelection: NSColor(hex: 0x4A4840))
                 : Theme(window: Color(hex: 0xFAF9F5), sidebar: Color(hex: 0xF0EEE6), text: Color(hex: 0x1F1E1D),
                         secondary: Color(hex: 0x5E5D59), muted: Color(hex: 0x8F8D86), border: Color.black.opacity(0.09),
                         hover: Color.black.opacity(0.04), selected: Color.black.opacity(0.07),
                         terminalBackground: NSColor(hex: 0xFAF9F5), terminalForeground: NSColor(hex: 0x2B2A27),
                         terminalSelection: NSColor(hex: 0xDCD9CC))
        },
        ThemeDefinition(id: "graphite", name: "Graphite (cool)") { dark in
            dark ? Theme(window: Color(hex: 0x1C1C1E), sidebar: Color(hex: 0x161618), text: Color(hex: 0xF2F2F7),
                         secondary: Color(hex: 0xAEAEB2), muted: Color(hex: 0x7C7C80), border: Color.white.opacity(0.08),
                         hover: Color.white.opacity(0.05), selected: Color.white.opacity(0.09),
                         terminalBackground: NSColor(hex: 0x1C1C1E), terminalForeground: NSColor(hex: 0xE5E5EA),
                         terminalSelection: NSColor(hex: 0x3A3A3C))
                 : Theme(window: Color(hex: 0xFFFFFF), sidebar: Color(hex: 0xF5F5F7), text: Color(hex: 0x1D1D1F),
                         secondary: Color(hex: 0x6E6E73), muted: Color(hex: 0x98989D), border: Color.black.opacity(0.08),
                         hover: Color.black.opacity(0.04), selected: Color.black.opacity(0.07),
                         terminalBackground: NSColor(hex: 0xFFFFFF), terminalForeground: NSColor(hex: 0x1D1D1F),
                         terminalSelection: NSColor(hex: 0xD1D1D6))
        },
        ThemeDefinition(id: "midnight", name: "Midnight (always dark)", alwaysDark: true) { _ in
            Theme(window: Color(hex: 0x121526), sidebar: Color(hex: 0x0D0F1C), text: Color(hex: 0xE6E8F2),
                         secondary: Color(hex: 0xA3A8C3), muted: Color(hex: 0x6E7391), border: Color.white.opacity(0.08),
                         hover: Color.white.opacity(0.05), selected: Color.white.opacity(0.09),
                         terminalBackground: NSColor(hex: 0x121526), terminalForeground: NSColor(hex: 0xDADDF0),
                         terminalSelection: NSColor(hex: 0x2E3352))
        },
        ThemeDefinition(id: "highContrast", name: "High contrast (always dark)", alwaysDark: true) { _ in
            Theme(window: .black, sidebar: .black, text: .white,
                         secondary: Color(hex: 0xE8E8E8), muted: Color(hex: 0xC2C2C2), border: Color.white.opacity(0.38),
                         hover: Color.white.opacity(0.10), selected: Color.white.opacity(0.14),
                         terminalBackground: .black, terminalForeground: .white,
                         terminalSelection: NSColor(hex: 0x264F78), outline: Color(hex: 0xF38518))
        },
    ]
    /// Built-in themes, then extensions' (set at launch).
    static var all = builtIn

    static func definition(_ id: String) -> ThemeDefinition { all.first { $0.id == id } ?? builtIn[0] }

    static func resolve(_ id: String, dark: Bool) -> Theme { definition(id).resolve(dark) }

    static func terminalFont(_ settings: AgentDESettings) -> NSFont {
        let size = CGFloat(settings.fontSize)
        if settings.fontName != "SF Mono", let font = NSFont(name: settings.fontName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static let fontChoices = ["SF Mono", "Menlo", "JetBrains Mono", "Fira Code", "Berkeley Mono", "IBM Plex Mono"]
        .filter { $0 == "SF Mono" || NSFont(name: $0, size: 12) != nil }
}
