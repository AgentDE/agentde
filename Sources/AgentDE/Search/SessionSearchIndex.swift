import Foundation

/// One searchable message from an agent's transcript, or one line of terminal scrollback.
struct SearchEntry {
    enum Role { case you, agent, terminal }
    let role: Role
    let text: String
    /// `text` lowercased once at index time, so each search is a plain substring scan.
    let lower: String
    let timestamp: Date?
    /// Position within its source, newest highest, for ordering hits.
    let order: Int
}

/// Where an agent keeps a session's conversation, and how one line of it reads (`Agent.transcript`): Claude's
/// session files, Codex's thread logs.
protocol TranscriptFormat {
    /// The session's transcript file, if there is one.
    func url(session: String, cwd: String) -> URL?
    /// A message from you or the agent on this line (not tool output or harness text).
    func entry(_ line: Data, order: Int) -> SearchEntry?
}

extension TranscriptFormat {
    static var iso: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

/// Indexes the conversational text of agents' transcripts (your prompts and the agent's replies; not tool output)
/// so searches across many sessions stay fast. Each file is read once, then only the bytes appended since, so
/// re-searching a live session costs a few milliseconds. Each agent's `TranscriptFormat` says where and how.
final class TranscriptIndex {
    private struct FileState {
        var offset: UInt64 = 0
        var remainder = Data()
        var entries: [SearchEntry] = []
    }

    private var files: [String: FileState] = [:]
    private var located: [String: URL] = [:]

    /// The session's transcript, remembered once found.
    func url(session: String, cwd: String, format: TranscriptFormat) -> URL? {
        if let known = located[session], FileManager.default.fileExists(atPath: known.path) { return known }
        let found = format.url(session: session, cwd: cwd)
        located[session] = found
        return found
    }

    static let chunkBytes: UInt64 = 4 << 20

    /// Drops everything: search runs again from the files when it's next used.
    func clear() {
        files = [:]
        located = [:]
    }

    /// Drops everything indexed for sessions outside `sessionIds`, so closed tabs and aged-out recent
    /// sessions don't hold memory for the rest of the run.
    func retainOnly(sessionIds: Set<String>) {
        let keep = Set(sessionIds.compactMap { located[$0]?.path })
        files = files.filter { keep.contains($0.key) }
        located = located.filter { sessionIds.contains($0.key) }
    }

    /// The session's entries, brought up to date with anything appended since the last call.
    func entries(sessionId: String, cwd: String, format: TranscriptFormat) -> [SearchEntry] {
        guard let url = url(session: sessionId, cwd: cwd, format: format) else { return [] }
        var state = files[url.path] ?? FileState()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return state.entries }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }   // rewritten: start over
        try? handle.seek(toOffset: state.offset)
        // Up to the size measured above, in chunks, so a multi-gigabyte transcript (tool output, images) is never
        // in memory at once; only its messages are kept. Bytes appended mid-read are picked up next time.
        while size > state.offset {
            let more = autoreleasepool { () -> Bool in
                guard let fresh = try? handle.read(upToCount: Int(min(size - state.offset, Self.chunkBytes))), !fresh.isEmpty else { return false }
                var chunk = state.remainder
                chunk.append(fresh)
                state.offset += UInt64(fresh.count)
                // Keep an unterminated last line for the next chunk (or the next call).
                if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                    state.remainder = Data(chunk[chunk.index(after: lastNewline)...])
                    chunk = Data(chunk[..<lastNewline])
                } else {
                    state.remainder = chunk
                    chunk = Data()
                }
                for line in chunk.split(separator: UInt8(ascii: "\n")) {
                    if let entry = format.entry(line, order: state.entries.count) { state.entries.append(entry) }
                }
                return true
            }
            if !more { break }
        }
        files[url.path] = state
        return state.entries
    }
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
