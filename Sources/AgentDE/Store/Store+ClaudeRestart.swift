import AppKit

/// Restarting a tab's Claude so it runs the installed Claude Code, keeping the tab and its session.
/// The rules and commands are in `ClaudeRestart` (plain functions, tested); this drives the terminal.
extension Store {
    enum ClaudeRestartOutcome { case restarted, skipped, failed }

    /// Claude tabs whose running Claude Code differs from the installed one.
    var outdatedClaudeTabs: [UUID] {
        groups.flatMap(\.tabs).filter { isClaudeOutdated($0.id) }.map(\.id)
    }

    func isClaudeOutdated(_ id: UUID) -> Bool {
        tab(id)?.kind == .claude && ClaudeVersion.isOutdated(running: runtime[id]?.claudeVersion, installed: installedClaudeVersion)
    }

    func claudeRestartCheck(_ id: UUID) -> ClaudeRestart.Check {
        guard let tab = tab(id) else { return .notClaude }
        let rt = runtime[id]
        return ClaudeRestart.check(kind: tab.kind, sessionId: tab.claudeSessionId, agentPresent: rt?.agentPresent ?? false,
                                   agentPid: rt?.agentPid, state: rt?.state ?? .none, restarting: restartingClaude.contains(id))
    }

    /// Right-click → Restart Claude: an idle Claude tab's agent restarts on the installed version, resuming its
    /// session. Foreground tabs get `/exit` and then `claude --resume <id>` in the same shell; background tabs
    /// have their job stopped and a new background session resuming it attached, in a fresh shell.
    func restartClaude(_ id: UUID, completion: ((ClaudeRestartOutcome) -> Void)? = nil) {
        let check = claudeRestartCheck(id)
        guard check == .eligible, let tab = tab(id), let pid = runtime[id]?.agentPid else {
            DebugLog.log("restart Claude in tab \(id.uuidString.prefix(8)) skipped: \(check)", "agent")
            completion?(.skipped)
            return
        }
        let from = runtime[id]?.claudeVersion ?? "?", to = installedClaudeVersion ?? "?"
        restartingClaude.insert(id)
        let finish = { [weak self] (outcome: ClaudeRestartOutcome) in
            self?.restartingClaude.remove(id)
            completion?(outcome)
        }
        switch ClaudeRestart.mode(attachJobId: tab.attachJobId) {
        case .foreground:
            DebugLog.log("restarting Claude in tab \(id.uuidString.prefix(8)) (\(from) -> \(to)): /exit, then resume", "agent")
            restartForeground(id, pid: pid, finish: finish)
        case .background:
            DebugLog.log("restarting Claude in tab \(id.uuidString.prefix(8)) (\(from) -> \(to)): stop job \(tab.attachJobId ?? ""), then resume in the background", "agent")
            restartBackground(id, pid: pid, finish: finish)
        }
    }

    private func restartForeground(_ id: UUID, pid: pid_t, finish: @escaping (ClaudeRestartOutcome) -> Void) {
        // Ctrl-C first: it clears a draft in Claude's input (so `/exit` isn't appended to it and sent), and on an
        // empty input it only arms "press again to exit".
        terminals.sendKey(id, [0x03])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            // Recheck right before typing: never type into a turn that just started, or into another program.
            guard self.runtime[id]?.agentPid == pid, Store.isAlive(pid),
                  [.none, .doneUnseen].contains(self.runtime[id]?.state ?? .none) else {
                DebugLog.log("restart Claude in tab \(id.uuidString.prefix(8)) stopped: it got busy", "agent")
                finish(.skipped)
                return
            }
            self.terminals.typeIntoTerminal(id, "/exit\r")
            Store.waitForExit(pid) { [weak self] exited in
                guard exited else {
                    DebugLog.log("restart Claude in tab \(id.uuidString.prefix(8)) gave up: Claude (pid \(pid)) didn't exit within 10 s of /exit", "agent")
                    finish(.failed)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let self, let tab = self.tab(id), let command = ClaudeRestart.resumeCommand(sessionId: tab.claudeSessionId) else {
                        finish(.failed)
                        return
                    }
                    self.terminals.typeIntoTerminal(id, command + "\r")
                    DebugLog.log("restarted Claude in tab \(id.uuidString.prefix(8)): \(command)", "agent")
                    finish(.restarted)
                }
            }
        }
    }

    private func restartBackground(_ id: UUID, pid: pid_t, finish: @escaping (ClaudeRestartOutcome) -> Void) {
        guard let job = tab(id)?.attachJobId else { finish(.failed); return }
        // `claude stop` keeps the conversation. Only once the job's process is gone can `claude --bg --resume`
        // continue the same session; while it still runs, Claude would start a copy instead.
        stopBackgroundJob(job)
        Store.waitForExit(pid) { [weak self] exited in
            guard let self else { return }
            guard exited else {
                DebugLog.log("restart Claude in tab \(id.uuidString.prefix(8)) gave up: job \(job) (pid \(pid)) didn't stop within 10 s", "agent")
                finish(.failed)
                return
            }
            guard self.tab(id) != nil else { finish(.failed); return }
            // A fresh shell runs the background launch (startup command, `claude --bg --resume <id>`, receipt,
            // `claude attach`); the receipt attaches this same tab to the new job.
            let session = self.terminals.replaceTerminal(id)
            Store.waitForHolderToGo(id) { [weak self] gone in
                guard let self, let (g, t) = self.locate(id) else { finish(.failed); return }
                if !gone { DebugLog.log("tab \(id.uuidString.prefix(8)): old terminal holder still there after 6 s", "agent") }
                self.groups[g].tabs[t].attachJobId = nil
                self.groups[g].tabs[t].forkOnStart = nil
                self.save()
                session.held = false
                session.launchInBackground = true
                session.startIfNeeded(self.groups[g].tabs[t])
                DebugLog.log("restarted Claude in tab \(id.uuidString.prefix(8)): resuming session \(self.groups[g].tabs[t].claudeSessionId?.prefix(8) ?? "?") as a new background job", "agent")
                finish(.restarted)
            }
        }
    }

    /// Restart Idle Claude Tabs: restarts every idle, outdated Claude tab one after another and skips busy ones,
    /// then shows a summary in the status bar.
    func restartIdleClaudeTabs() {
        guard claudeRestartNote?.hasPrefix("Restarting") != true else { return }
        var queue: [UUID] = [], busy = 0
        for id in outdatedClaudeTabs {
            switch claudeRestartCheck(id) {
            case .eligible: queue.append(id)
            case .working, .needsYou: busy += 1
            default: break
            }
        }
        DebugLog.log("restart idle Claude tabs: \(queue.count) idle, \(busy) busy", "agent")
        let total = queue.count
        var restarted = 0, failed = 0
        func next() {
            guard !queue.isEmpty else {
                let summary = ClaudeRestart.summary(restarted: restarted, busy: busy, failed: failed)
                DebugLog.log("restart idle Claude tabs: \(summary)", "agent")
                claudeRestartNote = summary
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    if self?.claudeRestartNote == summary { self?.claudeRestartNote = nil }
                }
                return
            }
            let id = queue.removeFirst()
            claudeRestartNote = "Restarting Claude · \(total - queue.count) of \(total)"
            restartClaude(id) { outcome in
                switch outcome {
                case .restarted: restarted += 1
                case .skipped: busy += 1
                case .failed: failed += 1
                }
                next()
            }
        }
        next()
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 && !ProcessTree.isZombie(pid) }

    /// Polls until `pid` is gone (or a zombie), for up to `timeout` seconds; calls back on the main thread.
    static func waitForExit(_ pid: pid_t, timeout: TimeInterval = 10, then done: @escaping (Bool) -> Void) {
        poll(until: { !isAlive(pid) }, deadline: Date().addingTimeInterval(timeout), then: done)
    }

    /// Polls until the tab's old holder has removed its socket.
    static func waitForHolderToGo(_ id: UUID, then done: @escaping (Bool) -> Void) {
        poll(until: { PtyHost.existingSocket(for: id) == nil }, deadline: Date().addingTimeInterval(6), then: done)
    }

    private static func poll(until condition: @escaping () -> Bool, deadline: Date, then done: @escaping (Bool) -> Void) {
        if condition() { done(true); return }
        if Date() > deadline { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(until: condition, deadline: deadline, then: done) }
    }
}
