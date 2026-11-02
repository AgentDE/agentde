import Foundation

/// JSON plugins' links, themes and palettes (`PluginManifest`), read once at launch from `<config>/plugins`.
/// Their widgets are the Widgets extension's to show.
final class JSONPlugins: AgentDEExtension {
    let id = "plugins"
    let name = "Plugins"
    let loaded: [PluginManifest.Loaded]

    static var directory: URL { URL(fileURLWithPath: AppBrand.configDirectory).appendingPathComponent("plugins") }

    init(directory: URL = JSONPlugins.directory) {
        loaded = PluginManifest.loadAll(in: directory)
        if !loaded.isEmpty { DebugLog.log("plugins: \(loaded.map(\.manifest.name).joined(separator: ", "))", "plugins") }
    }

    var linkRules: [LinkRule] { loaded.flatMap(\.manifest.linkRules) }
    var themes: [ThemeDefinition] { loaded.flatMap { $0.manifest.themeDefinitions { Theme.resolve("claude", dark: $0) } } }
    var palettes: [PaletteDefinition] { loaded.flatMap(\.manifest.paletteDefinitions) }
}
