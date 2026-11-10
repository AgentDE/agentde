import Foundation

/// Status any agent can report with its own hooks, for agents AgentDE has no registry for (Codex, Gemini CLI,
/// OpenCode…). Each tab's environment names a file, `AGENTDE_STATUS_FILE`; a hook writes one line to it:
/// the state (`working`, `needs-you` or `idle`), then the agent's pid (the hook's `$PPID`), then optionally what
/// it's waiting for. The monitor trusts a line only while that pid runs inside the tab, so a status can't
/// outlive its agent.
enum HookStatus {
    struct Report: Equatable {
        var state: String
        var pid: pid_t
        var detail: String?
        /// The agent's own session id, from the hook's input (`session_id`): how a new Codex tab learns the thread
        /// it resumes after a reboot.
        var session: String? = nil

        /// The state in the words of Claude's registry, so both kinds of status share one set of rules.
        var registryStatus: String {
            switch state {
            case "working": "busy"
            case "needs-you": "waiting"
            default: "idle"
            }
        }
    }

    static let directory = URL(fileURLWithPath: AppBrand.configDirectory).appendingPathComponent("status")

    static func file(for tab: UUID) -> URL { directory.appendingPathComponent(tab.uuidString) }

    /// A status line (`working 4242`, `needs-you 4242 approve rm -rf build`, `idle 4242`), optionally followed by
    /// a `session <id>` line.
    static func parse(_ text: String) -> Report? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, ["working", "needs-you", "idle"].contains(parts[0]),
              let pid = pid_t(parts[1]), pid > 1 else { return nil }
        let detail = parts.count > 2 ? String(parts[2].prefix(200)) : nil
        let session = lines.dropFirst().first { $0.hasPrefix("session ") }.map { String($0.dropFirst(8)) }.flatMap(SafeID.session)
        return Report(state: parts[0], pid: pid, detail: detail.flatMap { $0.isEmpty ? nil : $0 }, session: session)
    }

    /// Every tab's report in `directory`. Files whose agent has exited are removed.
    static func read(_ directory: URL = directory) -> [UUID: Report] {
        var reports: [UUID: Report] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard let tab = UUID(uuidString: file.lastPathComponent),
                  let text = try? String(contentsOf: file, encoding: .utf8), let report = parse(text) else { continue }
            if kill(report.pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            reports[tab] = report
        }
        return reports
    }

    /// The hook command for an agent's settings: reads the hook's input for its `session_id`, writes the state
    /// with the agent's pid (and the session), and never fails or prints, so it can't block or answer anything.
    static func hookCommand(_ state: String) -> String {
        #"in=$(cat 2>/dev/null); [ -n "${AGENTDE_STATUS_FILE-}" ] && { s=$(printf '%s' "$in" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1); printf '%s %s\n' STATE "$PPID" > "$AGENTDE_STATUS_FILE"; [ -n "$s" ] && printf 'session %s\n' "$s" >> "$AGENTDE_STATUS_FILE"; } 2>/dev/null; exit 0"#
            .replacingOccurrences(of: "STATE", with: state)
    }
}
