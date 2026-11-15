import Foundation

/// Codex's thread logs: `~/.codex/sessions/<year>/<month>/<day>/rollout-<time>-<thread id>.jsonl`.
struct CodexTranscript: TranscriptFormat {
    var sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")

    func url(session: String, cwd: String) -> URL? {
        let suffix = "-\(session).jsonl"
        guard let walker = FileManager.default.enumerator(at: sessionsDir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) { return url }
        return nil
    }

    private static let messageMarker = Data("\"type\":\"message\"".utf8)
    private static let dates = CodexTranscript.iso

    /// A `response_item` message from you or the agent (not its instructions or tool calls).
    func entry(_ line: Data, order: Int) -> SearchEntry? {
        guard line.range(of: Self.messageMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message",
              let role = payload["role"] as? String, role == "user" || role == "assistant",
              let parts = payload["content"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip empty turns and harness text (environment context, instructions), which start with a tag.
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        let date = (object["timestamp"] as? String).flatMap { Self.dates.date(from: $0) }
        return SearchEntry(role: role == "user" ? .you : .agent, text: text, lower: text.lowercased(), timestamp: date, order: order)
    }
}
