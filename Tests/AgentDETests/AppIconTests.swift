import Foundation
import Testing
@testable import AgentDE

@Suite("App icons")
struct AppIconTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func theDefaultIsAlwaysOfferedAndHasAnImage() {
        let resources = root.appendingPathComponent("Resources")
        #expect(AppIcons.ids(resources: resources) == ["agentde"])
        #expect(FileManager.default.fileExists(atPath: AppIcons.url("agentde", resources: resources)!.path))
        #expect(AppIcons.resolved("vaporwave-hologram", resources: resources) == AppIcons.defaultID)
    }

    @Test func theChoiceIsSavedAndOlderSettingsGetTheDefault() {
        #expect(AgentDESettings.decodeLenient(from: Data(#"{"fontSize": 14}"#.utf8)).appIcon == AppIcons.defaultID)
        #expect(AgentDESettings.decodeLenient(from: Data(#"{"appIcon": "portal-scan"}"#.utf8)).appIcon == "portal-scan")
    }
}

@Suite("App brand")
struct AppBrandTests {
    /// Outside an app whose Info.plist names a brand (as in tests), everything is AgentDE's.
    @Test func defaultsToAgentDE() {
        #expect(AppBrand.name == "AgentDE")
        #expect(AppBrand.dataFolder == "agentde")
        #expect(AppBrand.configDirectory == NSHomeDirectory() + "/.config/agentde")
        #expect(AppIcons.defaultID == "agentde")
    }
}
