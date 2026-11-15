import Foundation

/// Rewrites state saved by versions where Claude and Codex were tab kinds of their own, before it's decoded:
/// a tab's `kind` "claude"/"codex" becomes "agent" with that `agentID`, and its `claudeSessionId` /
/// `codexSessionId` becomes `agentSession`. Settings' `defaultTabKind` becomes `defaultAgent`.
enum SavedStateMigration {
    /// Returns whether the tab changed.
    @discardableResult
    static func tab(_ raw: inout [String: Any]) -> Bool {
        let claude = raw.removeValue(forKey: "claudeSessionId") as? String
        let codex = raw.removeValue(forKey: "codexSessionId") as? String
        var changed = claude != nil || codex != nil
        let kind = raw["kind"] as? String
        if kind == "claude" || kind == "codex" {
            raw["kind"] = "agent"
            raw["agentID"] = kind
            changed = true
        }
        if raw["agentSession"] == nil, let session = (kind == "codex" ? codex : claude) ?? claude ?? codex {
            raw["agentSession"] = session
        }
        return changed
    }

    /// Returns whether the settings changed.
    @discardableResult
    static func settings(_ raw: inout [String: Any]) -> Bool {
        guard let old = raw.removeValue(forKey: "defaultTabKind") as? String else { return false }
        if raw["defaultAgent"] == nil, ["claude", "codex", "shell"].contains(old) { raw["defaultAgent"] = old }
        return true
    }
}
