import AppKit
import SwiftTerm
import SwiftUI

/// A SwiftTerm view that reports focus and bells back to AgentDE. Its process lives in an
/// `agentde-pty` holder; `TerminalSession` connects the two.
final class AgentDETerminalView: TerminalView {
    var onFocus: (() -> Void)?
    var onBell: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func bell(source: Terminal) {
        onBell?()
    }
}

/// One tab's terminal: the view, and the connection to the holder running its shell. Lives as long as the
/// tab, independent of SwiftUI. The shell outlives it: quitting AgentDE only disconnects.
final class TerminalSession: NSObject, TerminalViewDelegate {
    let tabID: UUID
    let view: AgentDETerminalView
    private(set) var started = false
    weak var store: Store?
    /// A replacement session waits for the old holder to go before starting (`TerminalRegistry.replaceTerminal`).
    var held = false
    /// Start Claude as a background session even if background mode is off (a background tab's restart).
    var launchInBackground = false

    private var connection: PtyConnection?
    /// The tab's shell, as its holder reports it; 0 until connected.
    private(set) var shellPid: pid_t = 0
    /// While replaying output from before a reconnect, replies the terminal generates to old queries (cursor
    /// position, device attributes) are dropped rather than typed into the program.
    private var replaying = false
    private var exited = false
    private var terminating = false
    private var reconnecting = false
    /// Bytes of output since the last heartbeat; a stuck agent spewing output shows up in the log.
    private var bytesSinceHeartbeat = 0

    init(tabID: UUID, store: Store) {
        self.tabID = tabID
        self.store = store
        var options = TerminalOptions.default
        options.scrollback = max(1_000, store.settings.scrollbackLines)
        view = AgentDETerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), options: options)
        super.init()
        view.terminalDelegate = self
        view.optionAsMetaKey = true
        view.onFocus = { [weak self] in
            guard let self else { return }
            self.store?.terminalFocused(self.tabID)
        }
        view.onBell = { [weak self] in
            guard let self else { return }
            self.store?.bell(self.tabID)
        }
        applyAppearance()
    }

    func takeOutputCount() -> Int {
        defer { bytesSinceHeartbeat = 0 }
        return bytesSinceHeartbeat
    }

    func applyAppearance() {
        guard let store else { return }
        let theme = Theme.resolve(store.settings.theme, dark: TerminalSession.isDark(store.settings))
        view.font = Theme.terminalFont(store.settings)
        view.nativeBackgroundColor = theme.terminalBackground
        view.nativeForegroundColor = theme.terminalForeground
        view.selectedTextBackgroundColor = theme.terminalSelection
        if let group = store.groups.first(where: { $0.tabs.contains { $0.id == tabID } }) {
            view.caretColor = store.groupColor(group)
        }
        try? view.setUseMetal(store.settings.metalRenderer)
    }

    static func isDark(_ settings: AgentDESettings) -> Bool {
        switch settings.appearance {
        case .dark: return true
        case .light: return Theme.definition(settings.theme).alwaysDark
        case .system:
            return Theme.definition(settings.theme).alwaysDark
                || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// Connects the tab the first time it is shown: to its running holder if there is one (after a relaunch,
    /// the shell and agent are still going), else to a new holder running a fresh shell.
    func startIfNeeded(_ tab: TabModel) {
        guard !started, !held, store != nil else { return }
        started = true
        markStarted()
        let id = tabID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = PtyHost.existingSocket(for: id).flatMap(PtyHost.connect(path:))
            DispatchQueue.main.async {
                guard let self else { if let fd { close(fd) }; return }
                if let fd {
                    DebugLog.log("reattached tab \(id.uuidString.prefix(8)) kind=\(tab.kind.rawValue)", "tab")
                    self.attach(fd)
                } else {
                    self.launch(tab)
                }
            }
        }
    }

    /// At launch: connects to the tab's holder if it's still running, so its agent's status shows without
    /// visiting the tab. Starts nothing new.
    func reattachIfRunning() {
        guard !started, PtyHost.hasHolder(tabID) else { return }
        started = true
        let id = tabID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = PtyHost.existingSocket(for: id).flatMap(PtyHost.connect(path:))
            DispatchQueue.main.async {
                guard let self else { if let fd { close(fd) }; return }
                if let fd {
                    DebugLog.log("reattached tab \(id.uuidString.prefix(8)) at launch", "tab")
                    self.markStarted()
                    self.attach(fd)
                } else {
                    // A holder that died (a reboot, say) leaves its socket behind.
                    if let stale = PtyHost.existingSocket(for: id) { unlink(stale) }
                    self.started = false
                    if self.view.window != nil, let tab = self.store?.tab(id) { self.startIfNeeded(tab) }
                }
            }
        }
    }

    private func markStarted() {
        guard let store else { return }
        let id = tabID
        DispatchQueue.main.async { store.runtime[id, default: TabRuntime()].started = true }
    }

    private func attach(_ fd: Int32) {
        connection?.close()
        let connection = PtyConnection(fd: fd)
        connection.onEvent = { [weak self, weak connection] event in
            guard let self, let connection, connection === self.connection else { return }
            self.handle(event)
        }
        self.connection = connection
        connection.start()
    }

    private func handle(_ event: PtyConnection.Event) {
        switch event {
        case .hello(let version, _, let shell):
            if version != 1 { DebugLog.log("tab \(tabID.uuidString.prefix(8)) holder speaks protocol \(version)", "tab") }
            shellPid = shell
            if terminating { endProcesses(); retire() }
        case .output(let bytes, let replay):
            bytesSinceHeartbeat += bytes.count
            replaying = replay
            view.feed(byteArray: bytes[...])
            replaying = false
        case .replayEnd:
            // A SIGWINCH at the same size makes Claude Code repaint only what it thinks changed, from where it
            // thinks the cursor is; after a replay that's wrong, and the screen came out scrambled. A real size
            // change makes it repaint everything: one column narrower for a moment, then the true size.
            if view.getTerminal().cols > 2 {
                sendWindowSize(narrower: 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.sendWindowSize() }
            } else {
                sendWindowSize()
                connection?.redraw()
            }
        case .exited(let status):
            exited = true
            let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
            processTerminated(exitCode: code)
        case .closed:
            if terminating { retire(); return }
            guard !exited else { return }
            reconnect()
        }
    }

    /// The connection dropped without the shell exiting: try once more, then treat the tab as ended.
    private func reconnect() {
        guard !reconnecting else {
            DebugLog.log("tab \(tabID.uuidString.prefix(8)) lost its holder", "tab")
            processTerminated(exitCode: nil)
            return
        }
        reconnecting = true
        let id = tabID
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let fd = PtyHost.existingSocket(for: id).flatMap(PtyHost.connect(path:))
            DispatchQueue.main.async {
                guard let self else { if let fd { close(fd) }; return }
                guard let fd else {
                    DebugLog.log("tab \(id.uuidString.prefix(8)) lost its holder", "tab")
                    self.processTerminated(exitCode: nil)
                    return
                }
                DebugLog.log("tab \(id.uuidString.prefix(8)) reconnected to its holder", "tab")
                self.reconnecting = false
                self.view.feed(text: "\u{1b}c")   // the holder replays the screen again
                self.attach(fd)
            }
        }
    }

    private func sendWindowSize(narrower: Int = 0) {
        let terminal = view.getTerminal()
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        connection?.resize(rows: terminal.rows, cols: terminal.cols - narrower,
                           xPixels: Int(view.bounds.width * scale), yPixels: Int(view.bounds.height * scale))
    }

    /// Starts a new holder running the tab's shell, startup command and agent.
    private func launch(_ tab: TabModel) {
        guard let store else { return }
        DebugLog.log("start tab \(tab.id.uuidString.prefix(8)) kind=\(tab.kind.rawValue) cwd=\(tab.cwd.abbreviatingHome)"
                     + (tab.claudeSessionId.map { " resume=\($0.prefix(8))" } ?? "") + (tab.attachJobId.map { " attach=\($0)" } ?? ""), "tab")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let folderExists = Self.canEnter(folder: tab.cwd)
        let cwd = folderExists ? tab.cwd : NSHomeDirectory()
        var env = environment(for: tab)
        var args: [String]

        if !folderExists {
            // Never run the startup command or an agent somewhere else: open a plain shell and say why.
            DebugLog.log("tab \(tab.id.uuidString.prefix(8)) folder missing or not accessible: \(tab.cwd)", "tab")
            env["AGENTDE_MISSING_DIR"] = tab.cwd
            let note = "printf '\\033[33m\(AppBrand.name): %s is missing or not accessible, so this shell opened in ~ without the startup command or agent.\\033[0m\\n' \"$AGENTDE_MISSING_DIR\"; unset AGENTDE_MISSING_DIR"
            if ShellIntegration.supports(shell: shell) {
                args = ["-l"]
                if let userZdotdir = env["ZDOTDIR"] { env["AGENTDE_USER_ZDOTDIR"] = userZdotdir }
                env["ZDOTDIR"] = ShellIntegration.directory.path
                env["AGENTDE_RUN"] = note
            } else {
                args = ["-l"]
            }
        } else if tab.kind == .command {
            args = ["-l", "-i", "-c", tab.command ?? "true"]
        } else {
            // Startup command first (e.g. `conda activate myenv`), then the agent, if any.
            let background = (store.settings.backgroundAgents || launchInBackground) && tab.kind == .claude && tab.attachJobId == nil
            if background { store.pendingBackgroundLaunches[tab.id] = Date() }
            let run = [store.startupCommand(for: tab), TerminalSession.agentCommand(for: tab, background: background)]
                .compactMap { $0 }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            if ShellIntegration.supports(shell: shell) {
                args = ["-l"]
                if let userZdotdir = env["ZDOTDIR"] { env["AGENTDE_USER_ZDOTDIR"] = userZdotdir }
                env["ZDOTDIR"] = ShellIntegration.directory.path
                if !run.isEmpty { env["AGENTDE_RUN"] = run }
            } else {
                args = run.isEmpty ? ["-l"] : ["-l", "-i", "-c", "\(run)\nexec \(shell) -l"]
            }
        }
        let terminal = view.getTerminal()
        let (rows, cols) = (terminal.rows, terminal.cols)
        let environment = env.map { "\($0.key)=\($0.value)" }
        let id = tabID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let socket = PtyHost.socketPath(for: id)
            var fd: Int32?
            var problem: String?
            if !PtyHost.prepareDirectory() {
                problem = "its folder \(PtyHost.directory) isn't usable"
            } else if let holder = PtyHost.bundledHolder {
                if PtyHost.spawn(holder: holder, socket: socket, rows: rows, cols: cols, cwd: cwd, executable: shell,
                                 argv0: "-" + (shell as NSString).lastPathComponent, args: args, environment: environment) {
                    fd = PtyHost.connect(path: socket)
                }
                if fd == nil { problem = "the terminal holder didn't start" }
            } else {
                problem = "agentde-pty is missing from the app"
            }
            DispatchQueue.main.async {
                guard let self else { if let fd { close(fd) }; return }
                if let fd {
                    self.attach(fd)
                } else if self.terminating {
                    self.retire()
                } else {
                    DebugLog.log("tab \(id.uuidString.prefix(8)) couldn't start: \(problem ?? "unknown")", "tab")
                    self.view.feed(text: "\u{1b}[31m\(AppBrand.name) couldn't start this tab's terminal: \(problem ?? "unknown error").\u{1b}[0m\r\n")
                }
            }
        }
    }

    /// Whether a shell can start in `folder`: it exists, is a folder, and can be entered (search permission).
    static func canEnter(folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
            && access(folder, X_OK) == 0
    }

    /// The agent a tab runs after its startup command, or nil for a plain shell.
    static func agentCommand(for tab: TabModel, background: Bool = false) -> String? {
        // Ids are validated before they reach the shell; an invalid one is treated as absent.
        if let job = SafeID.job(tab.attachJobId) { return "claude attach \(job)" }
        let session = SafeID.session(tab.claudeSessionId)
        switch tab.kind {
        case .claude:
            let flags = session.map { " --resume \($0)" + (tab.forkOnStart == true ? " --fork-session" : "") } ?? ""
            return background ? backgroundLaunch(flags: flags) : "claude" + flags
        case .codex:
            return "codex" + (SafeID.session(tab.codexSessionId).map { " resume \($0)" } ?? "")
        case .shell:
            // A shell tab that was running Claude when AgentDE quit picks that session back up.
            return session.map { "claude --resume \($0)" }
        case .command, .files:
            return nil
        }
    }

    /// Starts Claude as a background session and attaches to it, so the agent outlives the tab and the app.
    /// The job id goes to `~/.config/<data folder>/attach/<tab id>`, where `AgentMonitor` picks it up, so the
    /// tab re-attaches after a relaunch. Falls back to a foreground Claude if the background start fails.
    static func backgroundLaunch(flags: String) -> String {
        """
        _mf_out=$(NO_COLOR=1 FORCE_COLOR=0 claude --bg\(flags) 2>&1)
        _mf_id=$(printf '%s\\n' "$_mf_out" | perl -pe 's/\\e\\[[0-9;]*m//g' | sed -nE 's/^backgrounded[^a-f0-9]+([a-f0-9]+).*$/\\1/p' | head -1)
        if [ -n "$_mf_id" ]; then
          _mf_receipt="$HOME/.config/\(AppBrand.dataFolder)/attach/$AGENTDE_TAB_ID"
          mkdir -p "${_mf_receipt:h}" && printf '%s\\n' "$_mf_id" > "$_mf_receipt.tmp" && mv -f "$_mf_receipt.tmp" "$_mf_receipt"
          claude attach "$_mf_id"
        else
          printf '%s\\n' "$_mf_out"; echo "\(AppBrand.name): couldn't start a background session, so Claude runs in this tab instead."
          claude\(flags)
        fi
        unset _mf_out _mf_id _mf_receipt
        """
    }

    private func environment(for tab: TabModel) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_")
            || key.hasPrefix("CLAUDE_AGENT") || key.hasPrefix("TERM_PROGRAM") || key == "PWD" || key == "OLDPWD"
            || key == "SHLVL" || key == "_" || key.hasPrefix("__CF") || key.hasPrefix("XPC_") {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = AppBrand.name
        // Programs that only emit clickable links for terminals they recognize (Claude Code among them) do so here.
        env["FORCE_HYPERLINK"] = "1"
        // Nothing inherited from an older launch names another tab or workstream.
        for key in ["WORKSTREAM_ID", "WORKSTREAM_TAB_ID"] { env.removeValue(forKey: key) }
        env["AGENTDE_TAB_ID"] = tab.id.uuidString
        if store?.settings.openInViewer ?? true { env.merge(OpenInViewer.environment(tab: tab.id, inherited: env)) { $1 } }
        // What extensions add (the workstream this terminal's agents attach to, say).
        if let store { env.merge(store.launchEnvironment(for: tab.id)) { $1 } }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// Ends the tab's processes. Interactive zsh ignores SIGTERM, so like closing a terminal window this sends
    /// SIGHUP to the shell and everything under it on the tab's terminal, then SIGKILL to anything still
    /// alive after 3 s. The holder reaps the shell and exits. Detached daemons (Claude's background sessions)
    /// keep running.
    func terminate() {
        terminating = true
        if shellPid > 0 || !started {
            if shellPid > 0 { endProcesses() }
            connection?.close()
            retire()
            return
        }
        // The holder is still starting: `.hello` ends its processes on arrival (or a failed start retires the
        // session). The registry keeps the session alive until then; give up after 15 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.onRetired != nil else { return }
            DebugLog.log("tab \(self.tabID.uuidString.prefix(8)) closed while starting; no shell reported in 15 s", "tab")
            self.connection?.close()
            self.retire()
        }
    }

    /// Called once a closed tab has ended (or given up on) its processes; the registry lets the session go.
    var onRetired: (() -> Void)?

    private func retire() {
        let done = onRetired
        onRetired = nil
        done?()
    }

    private func endProcesses() {
        let tree = ProcessTree.terminalDescendants(of: shellPid) + [shellPid]
        for pid in tree { kill(pid, SIGHUP) }
        connection?.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let survivors = tree.filter { kill($0, 0) == 0 && !ProcessTree.isZombie($0) }
            for pid in survivors { kill(pid, SIGKILL) }
            if !survivors.isEmpty { DebugLog.log("force-killed \(survivors.count) process(es) that ignored SIGHUP", "tab") }
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !replaying else { return }
        connection?.send(input: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sendWindowSize()
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// ⌘-click on a link (explicit OSC 8, or a URL or path SwiftTerm spots in the text).
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        store?.openLink(link, fromTab: tabID)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // A replay re-feeds old output; a copy it contains already happened once.
        guard !replaying, let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([text as NSString])
    }

    /// OSC 52 clipboard reads: answered only when allowed in Settings, and never during a replay.
    func clipboardRead(source: TerminalView) -> Data? {
        guard Self.answersClipboardRead(allowed: store?.settings.allowClipboardRead ?? false, replaying: replaying) else {
            DebugLog.log("tab \(tabID.uuidString.prefix(8)) denied a clipboard read (OSC 52)", "tab")
            return nil
        }
        return NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    static func answersClipboardRead(allowed: Bool, replaying: Bool) -> Bool { allowed && !replaying }

    /// Programs like Claude Code animate a spinner in the title many times a second. Only shell tabs use
    /// the title (as their name), so other tabs ignore it, and shell tabs publish at most once a second,
    /// with spinner glyphs stripped, so the window doesn't re-render on every frame.
    private var lastTitlePublish = Date.distantPast
    private var pendingTitle: String?

    func setTerminalTitle(source: TerminalView, title: String) {
        let cleaned = title.drop { !$0.isLetter && !$0.isNumber && $0 != "~" && $0 != "/" }
            .trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = self.store, store.tab(self.tabID)?.kind == .shell,
                  store.runtime[self.tabID]?.agentPresent != true else { return }
            self.pendingTitle = cleaned
            let wait = 1 - Date().timeIntervalSince(self.lastTitlePublish)
            if wait <= 0 { self.publishTitle() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.publishTitle() }
            }
        }
    }

    private func publishTitle() {
        guard let title = pendingTitle, let store else { return }
        pendingTitle = nil
        lastTitlePublish = Date()
        if store.runtime[tabID]?.terminalTitle != title { store.runtime[tabID, default: TabRuntime()].terminalTitle = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    private func processTerminated(exitCode: Int32?) {
        // Ended on purpose (closed, or replaced by a restart): a tab still there isn't this session's any more.
        if terminating { return }
        DebugLog.log("tab \(tabID.uuidString.prefix(8)) process exited code=\(exitCode.map(String.init) ?? "?")", "tab")
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = self.store else { return }
            if store.tab(self.tabID) != nil {
                store.closeTab(self.tabID, confirmIfBusy: false)
            } else {
                store.terminals.terminate(self.tabID)
            }
        }
    }
}
