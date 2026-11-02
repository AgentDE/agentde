import Foundation

/// The app's name and where it keeps its files: AgentDE by default. A build can rename itself
/// (`scripts/build-app.sh` with APP_NAME, DATA_FOLDER, DEFAULT_ICON) and then keeps its own state, holders,
/// logs and Keychain items, so two builds install side by side. Helpers inside the app read the same keys,
/// since `Bundle.main` is the enclosing app.
public enum AppBrand {
    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Shown in the window, menus and messages.
    public static let name = info("AgentDEBrandName") ?? "AgentDE"
    /// The folder under `~/.config` for saved state, terminal holders and shell files.
    public static let dataFolder = info("AgentDEDataFolder") ?? "agentde"
    public static var configDirectory: String { NSHomeDirectory() + "/.config/" + dataFolder }
    /// The app icon used when Settings hasn't chosen one (an `AppIcons` id).
    public static let defaultIcon = info("AgentDEDefaultIcon") ?? "agentde"
}
