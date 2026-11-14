import AppKit
import Testing
@testable import AgentDE

@Suite("JSON plugins")
struct PluginTests {
    private var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples")
    }

    @Test func theExamplePluginLoadsEverything() throws {
        let plugins = PluginManifest.loadAll(in: examples)
        let hello = try #require(plugins.first { $0.manifest.name == "Hello" })
        #expect(hello.manifest.widgets?.map(\.id) == ["hello.page", "hello.disk"])
        let rule = try #require(hello.manifest.linkRules.first)
        #expect("https://gist.github.com/someone/0123456789abcdef0123456789".range(of: rule.pattern, options: .regularExpression) != nil)
        let palette = try #require(hello.manifest.paletteDefinitions.first)
        #expect(palette.colors.first == 0x0B7285 && palette.colors.count == 8)
        let theme = try #require(hello.manifest.themeDefinitions { Theme.resolve("claude", dark: $0) }.first)
        #expect(theme.id == "hello.dusk" && theme.alwaysDark)
        #expect(theme.resolve(true).terminalBackground.hexString == "1B1B2F")
        #expect(hello.manifest.agents == [AgentDefinition(id: "hello.gemini", name: "Gemini", command: "gemini", tools: [
            AgentTool(id: "compact", label: "Compact", symbol: "rectangle.compress.vertical", command: "/compress"),
        ])])
    }

    @Test func badFilesAndUnsafeEntriesAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, json) in [("broken", "{ not json"), ("nameless", #"{"widgets": []}"#),
                             ("escape", #"{"name": "E", "widgets": [{"id": "x", "name": "X", "page": "../../secret.html"}], "links": [{"pattern": "(", "marker": "a"}]}"#)] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(name)/plugin.json"))
        }
        let plugins = PluginManifest.loadAll(in: dir)
        #expect(plugins.map(\.manifest.name) == ["E"])
        let problems = PluginManifest.problems(in: dir)
        #expect(problems.map(\.name) == ["broken", "nameless"])
        #expect(problems.first { $0.name == "nameless" }?.reason == "missing \"name\"")
        #expect(plugins[0].manifest.linkRules.isEmpty)        // a pattern that doesn't compile
        #expect(PluginManifest.loadAll(in: dir.appendingPathComponent("missing")).isEmpty)
    }

    @Test func colorsReadWithAndWithoutAlpha() {
        #expect(PluginManifest.rgba("#FF0000")! == (1, 0, 0, 1))
        #expect(PluginManifest.rgba("00FF0080")!.3 > 0.5 && PluginManifest.rgba("00FF0080")!.3 < 0.51)
        #expect(PluginManifest.rgba("#12345") == nil && PluginManifest.rgba("#GGGGGG") == nil)
    }
}

private extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
