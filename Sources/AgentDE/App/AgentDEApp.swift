import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var monitor: AgentMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppIcons.apply(store.settings.appIcon)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        DebugLog.log("launch \(version), pid \(getpid()), \(store.groups.count) groups, \(store.groups.reduce(0) { $0 + $1.tabs.count }) tabs, renderer=\(store.settings.metalRenderer ? "metal" : "coregraphics")")
        DebugLog.startWatchdog()
        ShellIntegration.install()
        OpenInViewer.install()
        store.notifier = Notifier(store: store)
        NSApp.activate(ignoringOtherApps: true)
        monitor = AgentMonitor(store: store)
        monitor?.start()
        store.reattachRunningTabs()
        AppRestart.watchForUpdates(store: store)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.markSeenVisibleTabs()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting only disconnects: every tab's shell and agent keep running in their holders, and the next
    /// launch reconnects to them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.log("quit")
        store.save()
        store.stopExtensions()
    }
}

/// Starts the app with these native extensions, in order. A build's `main.swift` calls it (the generated one
/// from `extensions.json`, or a workspace's own).
public enum AgentDEMain {
    static var extensions: [AgentDEExtension] = []

    /// Held for the life of the process (see `InstanceLock`).
    private static var lockFD: Int32 = -1

    public static func run(extensions: [AgentDEExtension]) -> Never {
        switch InstanceLock.acquire(statePath: PtyHost.stateFilePath) {
        case .acquired(let fd):
            lockFD = fd
        case .held:
            _ = NSApplication.shared
            let alert = NSAlert()
            alert.messageText = "\(AppBrand.name) is already running with this state"
            alert.informativeText = "Quit the other copy first. Both would fight over the same tabs. (\(PtyHost.stateFilePath.abbreviatingHome))"
            alert.runModal()
            exit(1)
        case .unavailable:
            DebugLog.log("couldn't open the instance lock beside \(PtyHost.stateFilePath); continuing without it")
        }
        self.extensions = extensions
        AgentDEApp.main()
        exit(0)
    }
}

struct AgentDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(AppBrand.name, id: "main") {
            RootView()
                .environment(delegate.store)
                .frame(minWidth: 760, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { AgentDECommands(store: delegate.store) }

        Settings {
            SettingsView().environment(delegate.store)
        }
    }
}

struct AgentDECommands: Commands {
    let store: Store

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Claude Tab") { store.newTab(kind: .claude) }.keyboardShortcut("t")
            Button("New Shell Tab") { store.newTab(kind: .shell) }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Codex Tab") { store.newTab(kind: .codex) }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("New File Explorer Tab") { store.newTab(kind: .files) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("New Group…") { store.newGroup() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") { store.closeActiveTab() }.keyboardShortcut("w")
            Button("Rename Tab") { if let id = store.activeTab?.id { store.renamingTabID = id } }.keyboardShortcut("r")
            Button("Fork Claude Session into New Tab") { store.forkTab() }.keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find in Tab…") { store.findInTab() }
                .keyboardShortcut("f")
            Button("Find Next") { store.findAgain(backwards: false) }
                .keyboardShortcut("g")
            Button("Find Previous") { store.findAgain(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Search All Sessions…") { store.paletteOpen = false; store.searchOpen.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Jump To…") { store.searchOpen = false; store.paletteOpen.toggle() }.keyboardShortcut("k")
            Button("Next Waiting Tab") { store.jumpToAttention() }.keyboardShortcut("j")
            Divider()
            Button("Next Tab") { store.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Group") { store.cycleGroup(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Group") { store.cycleGroup(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { store.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }
        CommandGroup(after: .appTermination) {
            Button("Restart \(AppBrand.name)") { AppRestart.restart() }
            let outdated = store.outdatedClaudeTabs.count
            Button("Restart Idle Claude Tabs" + (outdated > 0 ? " (\(outdated))" : "")) { store.restartIdleClaudeTabs() }
                .disabled(outdated == 0)
        }
        CommandGroup(replacing: .help) {
            Button("Open Debug Log") { DebugLog.openLog() }
            Button("Show Logs and Hang Samples in Finder") { DebugLog.revealFolder() }
        }
        CommandMenu("Layout") {
            Button("Toggle Sidebar") { store.sidebarVisible.toggle() }.keyboardShortcut("0")
            Button("Viewer Back") { store.stepViewer(1) }.keyboardShortcut("[")
            Button("Viewer Forward") { store.stepViewer(-1) }.keyboardShortcut("]")
            Button("Side Panel") { store.togglePanel() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Browser Above Tab") { store.toggleBrowser() }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Show Diff") { store.showDiff() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Open Folder in Cursor") { store.openInEditor() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Bigger Text") { store.settings.fontSize = min(store.settings.fontSize + 1, 24) }.keyboardShortcut("=")
            Button("Smaller Text") { store.settings.fontSize = max(store.settings.fontSize - 1, 9) }.keyboardShortcut("-")
        }
    }
}
