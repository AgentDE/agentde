import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView {
            Form {
                Picker("Appearance", selection: $store.settings.appearance) {
                    Text("Match system").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                Picker("Theme", selection: $store.settings.theme) {
                    ForEach(Theme.all, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Group colors", selection: $store.settings.palette) {
                    ForEach(GroupPalette.all, id: \.id) { palette in
                        HStack(spacing: 3) {
                            Text(palette.name)
                            ForEach(0..<6, id: \.self) { i in
                                Image(systemName: "square.fill").foregroundStyle(GroupPalette.color(i, palette.id))
                            }
                        }
                        .tag(palette.id)
                    }
                }
                Toggle("Translucent sidebar", isOn: $store.settings.translucentSidebar)
                Picker("Density", selection: $store.settings.density) {
                    Text("Comfortable").tag(Density.comfortable)
                    Text("Compact").tag(Density.compact)
                }
                Picker("Tabs", selection: $store.settings.tabsPosition) {
                    Text("Top").tag(TabsPosition.top)
                    Text("Bottom").tag(TabsPosition.bottom)
                }
                Slider(value: $store.settings.sidebarWidth, in: 180...320, step: 4) { Text("Sidebar width") }
            }
            .tabItem { Label("Look", systemImage: "paintpalette") }

            Form {
                Picker("Font", selection: $store.settings.fontName) {
                    ForEach(Theme.fontChoices, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size \(Int(store.settings.fontSize)) pt", value: $store.settings.fontSize, in: 9...24, step: 1)
                Toggle("GPU rendering (Metal, experimental)", isOn: $store.settings.metalRenderer)
                    .help("Uses much more CPU while agents are working, because it redraws the whole screen on every change.")
                Stepper("Scrollback \(store.settings.scrollbackLines.formatted()) lines",
                        value: $store.settings.scrollbackLines, in: 1_000...100_000, step: 5_000)
                    .help("History each terminal keeps. Applies to tabs opened after the change. More lines use more memory.")
                TextField("Startup command", text: $store.settings.startupCommand, prompt: Text("conda activate myenv"))
                    .help("Runs in every new tab before Claude or Codex starts. Groups can override it from their right-click menu.")
                Toggle("`open` shows files and pages in the tab's viewer", isOn: $store.settings.openInViewer)
                    .help("In tabs opened after the change, `open report.html` (also from Claude's ! and Bash commands) shows it in the viewer. /usr/bin/open always reaches the real one.")
                Toggle("Show recent sessions under each group", isOn: $store.settings.showRecentSessions)
                Toggle("Include Codex sessions", isOn: $store.settings.showCodexSessions)
                    .disabled(!store.settings.showRecentSessions)
                Stepper("Recent means the last \(Int(store.settings.recentSessionDays)) days",
                        value: $store.settings.recentSessionDays, in: 1...60, step: 1)
                    .disabled(!store.settings.showRecentSessions)
                Picker("New tabs start", selection: $store.settings.defaultTabKind) {
                    Text("Claude").tag(TabKind.claude)
                    Text("Codex").tag(TabKind.codex)
                    Text("Shell").tag(TabKind.shell)
                }
            }
            .tabItem { Label("Terminal", systemImage: "terminal") }

            Form {
                Toggle("Animate status dots", isOn: $store.settings.animations)
                Toggle("Sparkle when a long turn finishes", isOn: $store.settings.sparkles)
                Stepper("Long turn means \(Int(store.settings.sparkleAfterSeconds))s or more",
                        value: $store.settings.sparkleAfterSeconds, in: 5...600, step: 15)
                    .disabled(!store.settings.sparkles)
            }
            .tabItem { Label("Fun", systemImage: "sparkles") }

            Form {
                Section("Notifications") {
                    Toggle("When an agent needs you", isOn: $store.settings.notifyNeedsYou)
                    Toggle("When an agent finishes and you're elsewhere", isOn: $store.settings.notifyDone)
                    Toggle("Play a sound", isOn: $store.settings.notificationSound)
                }
                Section("Background agents") {
                    Toggle("Run Claude as background sessions", isOn: $store.settings.backgroundAgents)
                    Text("Every tab already keeps running when \(AppBrand.name) quits or updates. With this on, new Claude tabs also start as Claude background sessions (`claude --bg`) and attach, so closing a tab leaves the agent running too. Background sessions keep your conda env, but Claude's background service reorders PATH, so check `which python` if that matters.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("Pull requests") {
                    Toggle("Show the branch's PR and checks in the header", isOn: $store.settings.showPullRequests)
                    Picker("Open PRs in", selection: $store.settings.openPullRequestsIn) {
                        Text("GitHub").tag(PullRequestHost.github)
                        Text("Graphite").tag(PullRequestHost.graphite)
                    }
                }
            }
            .tabItem { Label("Agents", systemImage: "person.2") }

            ExtensionsSettings()
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }

            if AppIcons.allIDs.count > 1 {
                AppIconPicker(selection: $store.settings.appIcon)
                    .tabItem { Label("Icon", systemImage: "app.badge") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 420)
    }
}

/// Every app icon the build ships, in a grid.
private struct AppIconPicker: View {
    @Binding var selection: String

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(AppIcons.allIDs, id: \.self) { cell($0) }
            }
            .padding(16)
        }
    }

    private func cell(_ id: String) -> some View {
        let selected = AppIcons.resolved(selection) == id
        return Button { selection = id } label: {
            Group {
                if let image = AppIcons.image(id) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                }
            }
            .frame(width: 56, height: 56)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .hint(AppIcons.name(id))
    }
}


/// Each loaded extension's own settings, picked from a list.
private struct ExtensionsSettings: View {
    @Environment(Store.self) private var store
    @State private var selected: String?

    var body: some View {
        let withSettings = store.extensions.filter { $0.settingsView() != nil }
        if withSettings.isEmpty {
            Text("No extensions with settings are loaded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let current = withSettings.first { $0.id == selected } ?? withSettings[0]
            VStack(spacing: 0) {
                Picker("", selection: Binding(get: { current.id }, set: { selected = $0 })) {
                    ForEach(withSettings, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                current.settingsView()
            }
        }
    }
}
