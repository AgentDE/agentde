import AppKit
import SwiftUI

/// The open pull request for a branch, with its checks rolled up.
struct PullRequestStatus: Equatable {
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let passing: Int
    let failing: Int
    let pending: Int
    /// Failing check names, and the GitHub Actions run ids behind them (for `gh run view --log-failed`).
    let failingNames: [String]
    let failingRunIds: [String]
}

/// Looks up the active tab's pull request with `gh pr view`, at most once a minute per folder and branch.
final class PullRequestMonitor {
    private weak var store: Store?
    private let queue = DispatchQueue(label: "agentde.pull-requests", qos: .utility)
    private var lastFetch: [String: Date] = [:]
    private var inFlight = Set<String>()
    private let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    init(store: Store) {
        self.store = store
    }

    static func key(dir: String, branch: String) -> String { dir + "\u{1}" + branch }

    /// Refreshes the PR for a folder's current branch if it's stale. `force` skips the one-minute wait.
    func refresh(dir: String, force: Bool = false) {
        guard let gh, let branch = GitInfo.branch(at: dir) else { return }
        let key = Self.key(dir: dir, branch: branch)
        if !force, let last = lastFetch[key], Date().timeIntervalSince(last) < 60 { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        lastFetch[key] = Date()
        queue.async { [weak self] in
            let status = Self.fetch(gh: gh, dir: dir, branch: branch)
            DispatchQueue.main.async {
                self?.inFlight.remove(key)
                guard let store = self?.store else { return }
                if store.pullRequests[key] != .some(status) { store.pullRequests[key] = .some(status) }
            }
        }
    }

    /// Asks for the PR of `branch` explicitly, so a branch switch mid-request can't file B's PR under A.
    private static func fetch(gh: String, dir: String, branch: String) -> PullRequestStatus? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gh)
        task.arguments = ["pr", "view", branch, "--json", "number,title,url,isDraft,state,statusCheckRollup"]
        task.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["GH_PROMPT_DISABLED"] = "1"
        task.environment = env
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        if task.terminationStatus != 0 {
            DebugLog.log("gh pr view exit \(task.terminationStatus) in \(dir.abbreviatingHome)", "pr")
        }
        guard task.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["number"] as? Int,
              (object["state"] as? String) == "OPEN" else { return nil }

        var passing = 0, failing = 0, pending = 0
        var failingNames: [String] = [], runIds: [String] = []
        for check in object["statusCheckRollup"] as? [[String: Any]] ?? [] {
            // CheckRun: status + conclusion. StatusContext: state.
            let conclusion = (check["conclusion"] as? String ?? check["state"] as? String ?? "").uppercased()
            let status = (check["status"] as? String ?? "COMPLETED").uppercased()
            if status != "COMPLETED" || conclusion == "PENDING" || conclusion == "EXPECTED" {
                pending += 1
            } else if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) {
                failing += 1
                failingNames.append(check["name"] as? String ?? check["context"] as? String ?? "check")
                if let url = check["detailsUrl"] as? String ?? check["targetUrl"] as? String,
                   let range = url.range(of: #"/actions/runs/(\d+)"#, options: .regularExpression) {
                    let run = url[range].split(separator: "/").last.map(String.init) ?? ""
                    if !run.isEmpty, !runIds.contains(run) { runIds.append(run) }
                }
            } else if conclusion == "SUCCESS" || conclusion == "NEUTRAL" {
                passing += 1
            }
        }
        return PullRequestStatus(number: number, title: object["title"] as? String ?? "", url: object["url"] as? String ?? "",
                                 isDraft: object["isDraft"] as? Bool ?? false, passing: passing, failing: failing,
                                 pending: pending, failingNames: failingNames, failingRunIds: runIds)
    }
}

extension Store {
    func pullRequest(forDir dir: String) -> PullRequestStatus? {
        guard let branch = GitInfo.branch(at: dir) else { return nil }
        return pullRequests[PullRequestMonitor.key(dir: dir, branch: branch)] ?? nil
    }

    func openPullRequest(_ pr: PullRequestStatus) {
        var link = pr.url
        if settings.openPullRequestsIn == .graphite,
           let match = pr.url.range(of: #"github\.com/([^/]+)/([^/]+)/pull/(\d+)"#, options: .regularExpression) {
            let parts = pr.url[match].split(separator: "/")
            if parts.count >= 5 { link = "https://app.graphite.dev/github/pr/\(parts[1])/\(parts[2])/\(parts[4])" }
        }
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    /// Hands failing CI to the tab's Claude: types a prompt with the failing checks and their runs into the session.
    func fixChecksWithClaude(_ pr: PullRequestStatus) {
        guard let tab = activeTab else { return }
        guard runtime[tab.id]?.agentPresent == true else {
            alert("No Claude session in this tab", "Start Claude in this tab, then try again.")
            return
        }
        // Only type into an agent that's confirmed idle: working or waiting on a permission prompt both mean
        // the keystrokes would land somewhere other than a fresh prompt.
        guard state(tab.id) == .none || state(tab.id) == .doneUnseen else {
            alert(state(tab.id) == .needsYou ? "Claude is waiting on you" : "Claude is busy",
                  "Finish what Claude is doing in this tab, then try again.")
            return
        }
        let names = pr.failingNames.prefix(6).joined(separator: ", ")
        let logs = pr.failingRunIds.isEmpty
            ? "Read the failures with `gh pr checks \(pr.number)`"
            : "Read the failure logs with " + pr.failingRunIds.prefix(4).map { "`gh run view \($0) --log-failed`" }.joined(separator: " and ")
        let prompt = "CI checks are failing on PR #\(pr.number) (\(names)). \(logs), find the root cause, and fix it. "
            + "Tell me what was wrong before pushing anything."
        let target = tab.id
        let session = tab.claudeSessionId
        terminals.focus(target)
        // Recheck right before typing: the agent must still be the same idle session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.tab(target)?.claudeSessionId == session,
                  self.runtime[target]?.agentPresent == true, self.state(target) == .none || self.state(target) == .doneUnseen else { return }
            self.terminals.typeIntoTerminal(target, prompt + "\r")
        }
    }

    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
