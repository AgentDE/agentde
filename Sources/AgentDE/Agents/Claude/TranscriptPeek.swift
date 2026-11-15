import Foundation

/// Reads the end of a Claude transcript for the last thing the assistant said.
enum TranscriptPeek {
    /// `~/.claude/projects/<cwd with every non-alphanumeric character as "-">/<session>.jsonl`
    static func transcriptURL(sessionId: String, cwd: String) -> URL {
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects").appendingPathComponent(encoded)
            .appendingPathComponent(sessionId + ".jsonl")
    }

    static func lastAssistantText(sessionId: String, cwd: String, limit: Int = 180) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL(sessionId: sessionId, cwd: cwd)) else { return nil }
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
