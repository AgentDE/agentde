import Foundation

/// Reads the end of a Claude transcript for the last thing the assistant said.
enum TranscriptPeek {
    /// The transcript is found the way search finds it: under the folder Claude derives from `cwd`, else by its
    /// session id in any project folder (a folder name with non-ASCII letters, a worktree, a resume elsewhere).
    static func lastAssistantText(sessionId: String, cwd: String, limit: Int = 180) -> String? {
        guard let url = ClaudeTranscript().url(session: sessionId, cwd: cwd),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let tail = try? handle.readToEnd() else { return nil }
        let marker = Data("\"type\":\"assistant\"".utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["isSidechain"] as? Bool != true,
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text.count > limit ? String(text.prefix(limit)) + "…" : text }
        }
        return nil
    }
}
