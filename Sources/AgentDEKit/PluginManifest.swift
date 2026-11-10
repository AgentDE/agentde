import AppKit
import SwiftUI

/// A JSON plugin: a folder in `<config>/plugins/` with a `plugin.json` that adds widgets, viewer links, themes
/// palettes or agents without building anything. Every field but `name` is optional. See docs/EXTENDING.md.
///
///     {
///       "name": "Hello",
///       "widgets": [{"id": "hello", "name": "Hello", "page": "widget.html"},
///                   {"id": "load", "name": "Load", "command": "uptime", "every": 60}],
///       "links": [{"pattern": "https://wiki\\.example\\.com/page/\\w+", "marker": "wiki.example.com/page/"}],
///       "themes": [{"id": "dusk", "name": "Dusk", "alwaysDark": true, "dark": {"window": "#1B1B2F", …}}],
///       "palettes": [{"id": "sea", "name": "Sea", "colors": ["#0B7285", "#1098AD", …]}],
///       "agents": [{"id": "gemini", "name": "Gemini", "command": "gemini"}]
///     }
public struct PluginManifest: Decodable, Equatable {
    public var name: String
    public var widgets: [Widget]?
    public var links: [Link]?
    public var themes: [ThemeColors]?
    public var palettes: [Palette]?
    /// Terminal agents for the New menus.
    public var agents: [AgentDefinition]?

    public struct Widget: Decodable, Equatable {
        public var id: String
        public var name: String
        /// An HTML file in the plugin's folder, shown in a web view.
        public var page: String?
        /// A shell command (run with `zsh -lc` in the plugin's folder) whose output is shown.
        public var command: String?
        /// Seconds between runs of `command`, or reloads of `page`; at least 5. Nil runs it once per showing.
        public var every: Double?
    }

    public struct Link: Decodable, Equatable {
        public var pattern: String
        public var marker: String
    }

    public struct ThemeColors: Decodable, Equatable {
        public var id: String
        public var name: String
        public var alwaysDark: Bool?
        /// Colors by `Theme` field name, as "#RRGGBB" or "#RRGGBBAA". A missing field takes the built-in
        /// theme's; a missing `light` uses `dark` (and the other way round).
        public var dark: [String: String]?
        public var light: [String: String]?
    }

    public struct Palette: Decodable, Equatable {
        public var id: String
        public var name: String
        public var colors: [String]
    }

    /// A loaded plugin: its folder and manifest.
    public struct Loaded {
        public var folder: URL
        public var manifest: PluginManifest
    }

    /// Plugins in `directory` whose `plugin.json` doesn't read, with why, for Settings to show.
    public static func problems(in directory: URL) -> [(name: String, reason: String)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            let file = folder.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                _ = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: file))
                return nil
            } catch let DecodingError.keyNotFound(key, _) {
                return (folder.lastPathComponent, "missing \"\(key.stringValue)\"")
            } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
                return (folder.lastPathComponent, "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)")
            } catch {
                return (folder.lastPathComponent, "not valid JSON")
            }
        }
    }

    /// Every plugin in `directory` whose `plugin.json` reads, by folder name; the others are logged and skipped.
    public static func loadAll(in directory: URL) -> [Loaded] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            let file = folder.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                return Loaded(folder: folder, manifest: try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: file)))
            } catch {
                DebugLog.log("plugin \(folder.lastPathComponent): couldn't read plugin.json: \(error)", "plugins")
                return nil
            }
        }
    }

    // MARK: Conversions

    /// "#RRGGBB" or "#RRGGBBAA" as red, green, blue, alpha in 0…1.
    public static func rgba(_ text: String) -> (Double, Double, Double, Double)? {
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let v = digits.count == 6 ? value << 8 | 0xFF : value
        return (Double(v >> 24 & 0xFF) / 255, Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public var linkRules: [LinkRule] {
        (links ?? []).filter { (try? NSRegularExpression(pattern: $0.pattern)) != nil && !$0.marker.isEmpty }
            .map { LinkRule(pattern: $0.pattern, marker: $0.marker) }
    }

    public var paletteDefinitions: [PaletteDefinition] {
        (palettes ?? []).compactMap { palette in
            let colors = palette.colors.compactMap { text in
                Self.rgba(text).map { UInt32($0.0 * 255) << 16 | UInt32($0.1 * 255) << 8 | UInt32($0.2 * 255) }
            }
            return colors.isEmpty ? nil : PaletteDefinition(id: palette.id, name: palette.name, colors: colors)
        }
    }

    /// Themes, each color filled from `base` (a built-in theme) where the plugin doesn't give one.
    public func themeDefinitions(base: @escaping (_ dark: Bool) -> Theme) -> [ThemeDefinition] {
        (themes ?? []).map { colors in
            ThemeDefinition(id: colors.id, name: colors.name, alwaysDark: colors.alwaysDark ?? false) { dark in
                let given = (dark ? colors.dark ?? colors.light : colors.light ?? colors.dark) ?? [:]
                return Self.theme(given, base: base(dark))
            }
        }
    }

    static func theme(_ given: [String: String], base: Theme) -> Theme {
        func color(_ key: String, _ fallback: Color) -> Color {
            given[key].flatMap(rgba).map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2, opacity: $0.3) } ?? fallback
        }
        func nsColor(_ key: String, _ fallback: NSColor) -> NSColor {
            given[key].flatMap(rgba).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) } ?? fallback
        }
        return Theme(window: color("window", base.window), sidebar: color("sidebar", base.sidebar), text: color("text", base.text),
                     secondary: color("secondary", base.secondary), muted: color("muted", base.muted), border: color("border", base.border),
                     hover: color("hover", base.hover), selected: color("selected", base.selected),
                     terminalBackground: nsColor("terminalBackground", base.terminalBackground),
                     terminalForeground: nsColor("terminalForeground", base.terminalForeground),
                     terminalSelection: nsColor("terminalSelection", base.terminalSelection),
                     outline: given["outline"].flatMap(rgba).map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2, opacity: $0.3) } ?? base.outline)
    }
}
