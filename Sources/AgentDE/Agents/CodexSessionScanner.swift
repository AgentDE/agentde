import Foundation
import SQLite3

/// Finds recent Codex threads you started and named, from Codex's own thread database
/// (`~/.codex/state_<n>.sqlite`, opened read-only).
///
/// "Yours" means started from the Codex CLI (`codex-tui`) or the Codex desktop app, not a sub-agent thread,
/// and given a name. That leaves out `codex exec` runs and Codex tasks other agents launch (Claude Code's
/// Codex reviews, for example), which are unnamed.
final class CodexSessionScanner {
    private let codexDir: URL

    init(codexDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")) {
        self.codexDir = codexDir
    }

    /// Clients you drive yourself, as recorded in each thread's `originator`.
    static let interactiveOriginators = ["codex-tui", "Codex Desktop"]

    func scan(days: Double) -> [RecentSession] {
        guard let database = latestStateDatabase() else { return [] }
        // Read-only via a `mode=ro` URI. If Codex's write-ahead log can't be shared read-only, fall back to
        // `immutable=1`, which reads the main file as it stands (at worst missing the newest few seconds).
        for options in ["mode=ro", "immutable=1"] {
            if let sessions = query(database, options: options, days: days) { return sessions }
        }
        return []
    }

    private func query(_ database: URL, options: String, days: Double) -> [RecentSession]? {
        var db: OpaquePointer?
        let uri = "file:\(database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path)?\(options)"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let sql = """
            SELECT id, name, cwd, updated_at FROM threads
            WHERE updated_at > ? AND archived = 0
              AND originator IN (?, ?)
              AND source NOT LIKE '%subagent%'
              AND name IS NOT NULL AND trim(name) != ''
            ORDER BY updated_at DESC LIMIT 200
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, Int64(Date().addingTimeInterval(-days * 86_400).timeIntervalSince1970))
        sqlite3_bind_text(statement, 2, Self.interactiveOriginators[0], -1, transient)
        sqlite3_bind_text(statement, 3, Self.interactiveOriginators[1], -1, transient)
        var results: [RecentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), SafeID.session(id) != nil,
                  let name = text(statement, 1), let cwd = text(statement, 2) else { continue }
            let updated = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3)))
            results.append(RecentSession(sessionId: id, name: name.trimmingCharacters(in: .whitespaces), cwd: cwd,
                                         lastActive: updated, agent: .codex))
        }
        return results
    }

    /// Codex versions its state file (`state_5.sqlite`, …); the highest number is the live one.
    private func latestStateDatabase() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: codexDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .max { version($0) < version($1) }
    }

    private func version(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("state_".count)) ?? 0
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
