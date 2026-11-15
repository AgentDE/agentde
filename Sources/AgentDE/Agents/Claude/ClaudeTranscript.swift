import Foundation

/// Claude Code's session files: `~/.claude/projects/<cwd, every non-alphanumeric character as "-">/<session>.jsonl`.
struct ClaudeTranscript: TranscriptFormat {
    var projectsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")

    /// First under the folder Claude derives from `cwd`, else in any project folder (sessions resumed from another
    /// folder or a worktree live elsewhere).
    func url(session: String, cwd: String) -> URL? {
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        var candidates = [projectsDir.appendingPathComponent(encoded).appendingPathComponent(session + ".jsonl")]
        if let dirs = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
            candidates += dirs.map { $0.appendingPathComponent(session + ".jsonl") }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let dates = ClaudeTranscript.iso

    func entry(_ line: Data, order: Int) -> SearchEntry? {
        let isUser = line.range(of: Self.userMarker) != nil
        guard isUser || line.range(of: Self.assistantMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return nil }
        var text = ""
        if let plain = message["content"] as? String {
            text = plain
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip empty turns and harness-inserted text (command wrappers, reminders).
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        let date = (object["timestamp"] as? String).flatMap { Self.dates.date(from: $0) }
        return SearchEntry(role: isUser ? .you : .agent, text: text, lower: text.lowercased(), timestamp: date, order: order)
    }
}
