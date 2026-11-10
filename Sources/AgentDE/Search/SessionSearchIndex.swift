import Foundation

/// One searchable message from a Claude transcript, or one line of terminal scrollback.
struct SearchEntry {
    enum Role { case you, claude, codex, terminal }
    let role: Role
    let text: String
    /// `text` lowercased once at index time, so each search is a plain substring scan.
    let lower: String
    let timestamp: Date?
    /// Position within its source, newest highest, for ordering hits.
    let order: Int
}

/// Indexes the conversational text of Claude transcripts and Codex session logs (your prompts and the agent's
/// replies; not tool output) so searches across many sessions stay fast. Each file is read once, then only the bytes appended
/// since, so re-searching a live session costs a few milliseconds.
final class TranscriptIndex {
    private struct FileState {
        var offset: UInt64 = 0
        var remainder = Data()
        var entries: [SearchEntry] = []
    }

    private var files: [String: FileState] = [:]
    private var located: [String: URL] = [:]
    private let projectsDir: URL
    private let codexDir: URL

    init(projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
         codexDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")) {
        self.projectsDir = projectsDir
        self.codexDir = codexDir
    }

    /// Codex keeps each thread as `sessions/<year>/<month>/<day>/rollout-<time>-<thread id>.jsonl`.
    func codexLogURL(sessionId: String) -> URL? {
        if let known = located[sessionId], FileManager.default.fileExists(atPath: known.path) { return known }
        let suffix = "-\(sessionId).jsonl"
        var found: URL?
        if let walker = FileManager.default.enumerator(at: codexDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) { found = url; break }
        }
        located[sessionId] = found
        return found
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Finds `<session>.jsonl`: first under the folder Claude derives from `cwd`, else in any project folder
    /// (sessions resumed from another folder or a worktree live elsewhere).
    func transcriptURL(sessionId: String, cwd: String) -> URL? {
        if let known = located[sessionId], FileManager.default.fileExists(atPath: known.path) { return known }
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        var candidates = [projectsDir.appendingPathComponent(encoded).appendingPathComponent(sessionId + ".jsonl")]
        if let dirs = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
            candidates += dirs.map { $0.appendingPathComponent(sessionId + ".jsonl") }
        }
        let found = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        located[sessionId] = found
        return found
    }

    /// Drops everything indexed for sessions outside `sessionIds`, so closed tabs and aged-out recent
    /// sessions don't hold memory for the rest of the run.
    func retainOnly(sessionIds: Set<String>) {
        let keep = Set(sessionIds.compactMap { located[$0]?.path })
        files = files.filter { keep.contains($0.key) }
        located = located.filter { sessionIds.contains($0.key) }
    }

    /// The session's entries, brought up to date with anything appended since the last call.
    func entries(sessionId: String, cwd: String, codex: Bool = false) -> [SearchEntry] {
        guard let url = codex ? codexLogURL(sessionId: sessionId) : transcriptURL(sessionId: sessionId, cwd: cwd) else { return [] }
        var state = files[url.path] ?? FileState()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return state.entries }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }   // rewritten: start over
        if size > state.offset {
            try? handle.seek(toOffset: state.offset)
            // Read exactly up to the size measured above and advance by what was actually read, so bytes
            // appended mid-read are picked up next time instead of being read twice.
            guard let fresh = try? handle.read(upToCount: Int(size - state.offset)) else { return state.entries }
            var chunk = state.remainder
            chunk.append(fresh)
            state.offset += UInt64(fresh.count)
            // Keep an unterminated last line for next time.
            if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                state.remainder = Data(chunk[chunk.index(after: lastNewline)...])
                chunk = Data(chunk[..<lastNewline])
            } else {
                state.remainder = chunk
                chunk = Data()
            }
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
                if let entry = codex ? Self.parseCodex(line, order: state.entries.count) : Self.parse(line, order: state.entries.count) {
                    state.entries.append(entry)
                }
            }
        }
        files[url.path] = state
        return state.entries
    }

    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)

    private static func parse(_ line: Data, order: Int) -> SearchEntry? {
        let isUser = line.range(of: userMarker) != nil
        guard isUser || line.range(of: assistantMarker) != nil,
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
        let date = (object["timestamp"] as? String).flatMap { iso.date(from: $0) }
        return SearchEntry(role: isUser ? .you : .claude, text: text, lower: text.lowercased(), timestamp: date, order: order)
    }
}

extension TranscriptIndex {
    private static let codexMessageMarker = Data("\"type\":\"message\"".utf8)

    /// A Codex `response_item` message from you or the agent (not its instructions or tool calls).
    static func parseCodex(_ line: Data, order: Int) -> SearchEntry? {
        guard line.range(of: codexMessageMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message",
              let role = payload["role"] as? String, role == "user" || role == "assistant",
              let parts = payload["content"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip empty turns and harness text (environment context, instructions), which start with a tag.
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        let date = (object["timestamp"] as? String).flatMap { codexDate.date(from: $0) }
        return SearchEntry(role: role == "user" ? .you : .codex, text: text, lower: text.lowercased(), timestamp: date, order: order)
    }

    private static let codexDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Matching shared by every source: all words must appear (case-insensitive); the snippet centers on the first.
enum SearchMatch {
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    static func matches(_ entry: SearchEntry, _ terms: [String]) -> Bool {
        terms.allSatisfy { entry.lower.contains($0) }
    }

    /// A one-line excerpt around the first term, with an ellipsis where it's cut.
    static func snippet(_ text: String, _ terms: [String], radius: Int = 70) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        guard let first = terms.first, let range = flat.range(of: first, options: .caseInsensitive) else {
            return String(flat.prefix(radius * 2))
        }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
