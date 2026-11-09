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

    /// One status line: `working 4242`, `needs-you 4242 approve rm -rf build`, `idle 4242`.
    static func parse(_ text: String) -> Report? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, ["working", "needs-you", "idle"].contains(parts[0]),
              let pid = pid_t(parts[1]), pid > 1 else { return nil }
        let detail = parts.count > 2 ? String(parts[2].prefix(200)) : nil
        return Report(state: parts[0], pid: pid, detail: detail.flatMap { $0.isEmpty ? nil : $0 })
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

    /// The hook command for an agent's settings: reads (and ignores) the hook's input, writes the state with
    /// the agent's pid, and never fails or prints, so it can't block or answer anything for the agent.
    static func hookCommand(_ state: String) -> String {
        #"cat >/dev/null 2>&1; [ -n "${AGENTDE_STATUS_FILE-}" ] && printf '%s %s\n' STATE "$PPID" > "$AGENTDE_STATUS_FILE" 2>/dev/null; exit 0"#
            .replacingOccurrences(of: "STATE", with: state)
    }
}
