import Foundation

enum Appearance: String, Codable, CaseIterable { case system, light, dark }
enum Density: String, Codable, CaseIterable { case compact, comfortable }

struct AgentDESettings: Codable, Equatable {
    /// The theme a new install starts with.
    static let defaultTheme = "highContrast"

    var appearance: Appearance = .system
    /// A theme id (`Theme.builtIn`, or an extension's).
    var theme = AgentDESettings.defaultTheme
    /// A group palette id (`GroupPalette.builtIn`, or an extension's).
    var palette = "soft"
    var fontName: String = "SF Mono"
    var fontSize: Double = 13
    var density: Density = .comfortable
    var animations: Bool = true
    var sparkles: Bool = true
    /// Termi, the mascot, hangs out in the tab strip's free space (`TermiStrip`).
    var termi: Bool = false
    var sidebarWidth: Double = 224
    /// What New tab starts: an agent's id, or "shell".
    var defaultAgent: String = ClaudeAgent.id
    /// Show recently active Claude sessions under each group, one click to resume.
    var showRecentSessions: Bool = true
    /// New Claude and Codex tabs ask for a name first (Claude's session gets it with `--name`).
    var askSessionName: Bool = true
    /// The small row of Claude actions in the chat's top-right corner (`ChatTools`).
    var chatTools: Bool = true
    /// The sidebar shows only tabs active today (`Store.isActiveToday`) and hides Recent.
    var sidebarActiveOnly: Bool = false
    var recentSessionDays: Double = 14
    /// Include named Codex threads in the Recent lists.
    var showCodexSessions: Bool = true
    /// `open <file or web page>` in a tab (also from Claude's `!` and Bash commands) shows it in the tab's viewer.
    var openInViewer: Bool = true
    /// Whether programs in a tab may read the clipboard (OSC 52). Off: any program, even over SSH, could
    /// otherwise read what you last copied.
    var allowClipboardRead: Bool = false
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
    /// How often you've opened each file or page in a viewer (`Store.viewerOpenCounts`).
    var viewerOpens: [String: Int]?
    /// When you last opened each file or page in a viewer (`Store.viewerOpenedAt`).
    var viewerOpenedAt: [String: Date]?
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
