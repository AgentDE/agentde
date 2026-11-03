import Foundation

enum Appearance: String, Codable, CaseIterable { case system, light, dark }
enum Density: String, Codable, CaseIterable { case compact, comfortable }
enum TabsPosition: String, Codable, CaseIterable { case top, bottom }

struct AgentDESettings: Codable, Equatable {
    var appearance: Appearance = .system
    /// A theme id (`Theme.builtIn`, or an extension's).
    var theme = "claude"
    /// A group palette id (`GroupPalette.builtIn`, or an extension's).
    var palette = "soft"
    var fontName: String = "SF Mono"
    var fontSize: Double = 13
    var density: Density = .comfortable
    var tabsPosition: TabsPosition = .top
    var animations: Bool = true
    var sparkles: Bool = true
    var translucentSidebar: Bool = true
    /// SwiftTerm's Metal renderer. Off by default: it rebuilds the whole screen on every change, so a busy
    /// Claude spinner keeps the main thread busy. The CoreGraphics renderer redraws only changed rows.
    var metalRenderer: Bool = false
    var sidebarWidth: Double = 224
    var defaultTabKind: TabKind = .claude
    /// Show recently active Claude sessions under each group, one click to resume.
    var showRecentSessions: Bool = true
    var recentSessionDays: Double = 14
    /// Include named Codex threads in the Recent lists.
    var showCodexSessions: Bool = true
    /// `open <file or web page>` in a tab (also from Claude's `!` and Bash commands) shows it in the tab's viewer.
    var openInViewer: Bool = true
    /// Shell commands run in every new tab before its agent starts, e.g. `conda activate myenv`.
    var startupCommand: String = ""
    /// Seconds an agent must have been working for its finish to earn a sparkle.
    var sparkleAfterSeconds: Double = 45
    /// Lines of history each terminal keeps. Applies to tabs opened after a change.
    var scrollbackLines: Int = 10_000
    /// macOS notifications when an agent needs you or finishes while you're looking elsewhere.
    var notifyNeedsYou: Bool = true
    var notifyDone: Bool = true
    var notificationSound: Bool = true
    /// Run new Claude tabs as Claude background sessions (`claude --bg` + `claude attach`), so closing
    /// a tab leaves the agent running.
    var backgroundAgents: Bool = false
    /// Show the branch's pull request and its checks in the header.
    var showPullRequests: Bool = true
    var openPullRequestsIn: PullRequestHost = .github
    /// The Dock icon (an `AppIcons` id).
    var appIcon: String = AppIcons.defaultID
    /// Native extensions' own settings, as JSON, by extension id.
    var extensionSettings: [String: String]?
}

enum PullRequestHost: String, Codable, CaseIterable { case github, graphite }

struct SavedState: Codable {
    var groups: [GroupModel]
    var selectedGroupID: UUID?
    var settings: AgentDESettings
}

extension AgentDESettings {
    /// Decodes settings saved by any AgentDE version: keys missing from older files take their defaults.
    static func decodeLenient(from data: Data) -> AgentDESettings {
        guard let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentDESettings())) as? [String: Any],
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return AgentDESettings() }
        // Merge saved keys one at a time, keeping each only if the result still decodes, so one bad value
        // (say, an enum case from a newer version) resets just that setting rather than all of them.
        var merged = defaults
        for (key, value) in saved {
            var candidate = merged
            candidate[key] = value
            if let data = try? JSONSerialization.data(withJSONObject: candidate),
               (try? JSONDecoder().decode(AgentDESettings.self, from: data)) != nil {
                merged = candidate
            }
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return AgentDESettings() }
        return (try? JSONDecoder().decode(AgentDESettings.self, from: mergedData)) ?? AgentDESettings()
    }
}
