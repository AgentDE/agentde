# Extending AgentDE

Two ways to add to AgentDE:

| Kind | What it is | Can do | Needs a build |
|---|---|---|---|
| Native extension | A Swift package with a class conforming to `AgentDEExtension` | Every hook below: panels, widgets, tab environment, menus, settings, tickets, links, themes | Yes: listed in `extensions.json`, compiled into the app |
| JSON plugin | A folder with a `plugin.json` in `~/.config/agentde/plugins/` | Widgets (an HTML page or a command's output), viewer links, themes, palettes | No: read at launch |

**Contents:** [Native extensions](#native-extensions) · [Hooks](#hooks) · [The host](#the-host) · [Saving data](#per-tab-values-and-settings) · [Example](#an-example-extension) · [Adding it to a build](#adding-it-to-a-build) · [Widgets](#widgets) · [Ticket providers](#ticket-providers) · [Link rules](#link-rules) · [Themes and palettes](#themes-and-palettes) · [JSON plugins](#json-plugins)

## Native extensions

The API is the `AgentDEKit` library (`Sources/AgentDEKit/`):

| File | Holds |
|---|---|
| `Extension.swift` | `AgentDEExtension` (the hooks), `AgentDEHost` (what the app offers), `TabInfo`, `GroupInfo`, `ExtensionAction`, `LinkRule`, `ThemeDefinition`, `PaletteDefinition`, `TicketInfo`, `TicketProvider` |
| `Theme.swift` | `Theme` (every color the app paints) and the `\.theme` environment value |
| `TicketRow.swift` | `TicketRow`: one ticket on a line, for lists of tickets |
| `Components.swift`, `Hint.swift`, `FileIcons.swift` | Shared views: `.hint(_:)` hover labels, `AskRing`, file icons and others |
| `DebugLog.swift` | `DebugLog.log(_:_:)`: writes to the app's debug log |
| `AppBrand.swift` | The build's name (`AppBrand.name`) and folder (`AppBrand.configDirectory`) |
| `Worktrees.swift`, `SafeID.swift`, `Tabs.swift`, `PluginManifest.swift` | Git worktrees, id validation for shell commands, `TabKind` and `AgentState`, the JSON plugin format |

An extension is a class with an `id` (stable: it namespaces the extension's saved data) and a `name` (shown in Settings). Every hook has a default that does nothing, so an extension implements only what it adds. The app creates extensions at launch, in `extensions.json` order, calls `start(host:)` after saved state is loaded and `stop()` at quit. Hooks are called on the main thread.

### Hooks

| Hook | Called or read |
|---|---|
| `start(host:)` | Once at launch, after saved state is loaded; keep the host |
| `stop()` | At quit; save anything that's behind |
| `launchEnvironment(for:)` | When a tab's shell starts: environment variables to add |
| `agentSessionsChanged()` | After the app re-reads which agent session each tab runs (Claude started, `/clear`, a resume) |
| `liveSessionsChanged(_:)` | After each registry poll (once a second): the agent sessions running anywhere on the Mac |
| `agentWentIdle(_:)` | A tab's agent finished a turn or is waiting |
| `tabClosing(_:keepAgent:)` | A tab is closing; with `keepAgent` its background agent keeps running |
| `backgroundSessionOpened(_:session:forkParent:)` | The app opened a tab for a background session (`/fork`, `claude --bg`); `forkParent` is the session it was forked from, when known |
| `wantsAttention(_:)` | Whether a tab gets a soft attention ring without its agent being stopped |
| `panel(for:)` | The side panel beside an agent tab's chat; the first extension that returns one owns it |
| `sidebarFooter()` | The area at the bottom of the sidebar; the first extension that returns one owns it |
| `windowOverlay()` | A view drawn over the whole window that passes clicks through |
| `viewerAccessory(for:item:)` | Controls in the viewer's header for the file path or link it shows |
| `title(forLink:in:)` | A better title for a link shown in the viewer |
| `newMenuItems(for:)` | Items for a group's right-click **New** menu (`ExtensionAction`: title, SF Symbol, action) |
| `settingsView()` | The extension's section in Settings → Extensions |
| `linkRules` | Links that open in the viewer rather than the browser; read once at launch |
| `themes` | Themes added to Settings → Look; read once at launch |
| `palettes` | Group color palettes added to Settings → Look; read once at launch |
| `ticketProviders` | Trackers whose tickets this extension can look up |

`TabInfo` is a tab as extensions see it: `id`, `groupID`, `kind` (`claude`, `codex`, `shell`, `command`, `files`), `folder`, `groupFolder`, `title`, `agentSession` (Claude's session id or Codex's thread id), `agentPresent`, `state` (`none`, `working`, `needsYou`, `doneUnseen`), `viewerItem`, and `isAgent`.

### The host

`AgentDEHost` is the app's own observable state, so a SwiftUI view that reads it updates when it changes. Main thread only.

| Member | Gives or does |
|---|---|
| `allTabs`, `allGroups`, `tabInfo(_:)`, `activeTabID` | Tabs and groups, in sidebar order |
| `liveSessions` | Agent sessions running anywhere on the Mac |
| `rateLimitsUsed` | Claude's 5-hour and 7-day limits used, 0–100, when known |
| `animations` | Whether the user wants motion (Settings → Fun, and Reduce Motion) |
| `extensions` | The loaded extensions, for working with each other: `host.extensions.compactMap { $0 as? SomeProtocol }` |
| `selectTab(_:focus:)` | Selects a tab |
| `type(_:into:)` | Types text into a tab's terminal, as if pasted; `"\r"` presses Return |
| `openInViewer(_:tab:select:)` | Shows a file path or link in a tab's viewer |
| `openTab(kind:in:folder:title:)` | Opens a new tab and returns its id |
| `value`, `setValue` | Per-tab values (below) |
| `settingsData`, `setSettingsData`, `settings(_:for:fallback:)`, `saveSettings(_:for:)` | The extension's settings (below) |
| `showProblem(_:_:)` | A modal alert with one OK button |
| `configDirectory` | The app's folder under `~/.config` (`~/.config/agentde`, or a brand's) |

### Per-tab values and settings

| Data | API | Saved as |
|---|---|---|
| Small strings kept with a tab | `host.value(key, tab:, for: self)`, `host.setValue(value, key, tab:, for: self)`; nil removes | `extensionData["<extension id>.<key>"]` on the tab in `state.json` |
| The extension's settings | `host.settings(T.self, for: self, fallback:)` to read, `host.saveSettings(value, for: self)` to write, for any `Codable` type | JSON under `settings.extensionSettings["<extension id>"]` in `state.json` |

Add new settings fields with defaults, so older saved settings still decode.

### An example extension

A package `agentde-hello` with one library target, depending on `AgentDEKit`:

```swift
// Sources/AgentDEHello/HelloExtension.swift
import AgentDEKit
import SwiftUI

struct HelloSettings: Codable { var greeting = "Hello" }

public final class HelloExtension: AgentDEExtension {
    public let id = "hello"
    public let name = "Hello"
    private var host: AgentDEHost?

    public init() {}

    public func start(host: AgentDEHost) { self.host = host }

    // Every tab's shell gets HELLO_TAB.
    public func launchEnvironment(for tab: TabInfo) -> [String: String] { ["HELLO_TAB": tab.id.uuidString] }

    // Group → New → Say hello: opens a shell tab and greets.
    public func newMenuItems(for group: GroupInfo) -> [ExtensionAction] {
        [ExtensionAction("Say hello", symbol: "hand.wave") { [weak self] in
            guard let self, let host, let tab = host.openTab(kind: .shell, in: group.id, folder: nil, title: "hello") else { return }
            let greeting = host.settings(HelloSettings.self, for: self, fallback: HelloSettings()).greeting
            host.type("echo \(greeting)\r", into: tab)
        }]
    }

    // Wiki pages open in the viewer.
    public var linkRules: [LinkRule] { [LinkRule(pattern: #"https://wiki\.example\.com/page/\w+"#, marker: "wiki.example.com/page/")] }
}
```

```swift
// Package.swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "agentde-hello",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AgentDEHello", targets: ["AgentDEHello"])],
    dependencies: [.package(path: "../agentde")],
    targets: [.target(name: "AgentDEHello", dependencies: [.product(name: "AgentDEKit", package: "agentde")])]
)
```

### Adding it to a build

Put it beside `agentde/` (or give its `repo`, and the build clones it there) and add an entry to `agentde/extensions.json` (or a copy passed with `make EXTENSIONS=…`):

```json
{
  "extensions": [
    { "package": "../agentde-widgets", "product": "AgentDEWidgets", "create": "WidgetsExtension()" },
    { "package": "../agentde-hello", "repo": "https://github.com/you/agentde-hello", "product": "AgentDEHello", "create": "HelloExtension()" }
  ]
}
```

| Field | What |
|---|---|
| `package` | The package's folder, relative to the extensions file |
| `repo` | Optional: a git URL to clone the package from when the folder isn't there. Sibling packages it depends on (`.package(path: "../x")`) are cloned from the same owner |
| `product` | Its library product; also the module the generated `main.swift` imports |
| `create` | A Swift expression that creates the extension: an initializer call |
| `helpers` | Optional: `[{"package": …, "repo": …, "product": …}]`, executables built and copied into `Contents/MacOS` |

`scripts/assemble.py` turns the file into a small package (`.build/app-package`) whose `main.swift` calls `AgentDEMain.run(extensions: [...])`, and `scripts/build-app.sh` builds and bundles it. A workspace that builds its own app instead calls `AgentDEMain.run(extensions:)` from its own executable and sets `APP_PACKAGE`, `APP_PRODUCT` and `APP_HELPERS` for `build-app.sh`.

## Widgets

The sidebar widget spot belongs to the Widgets extension (`agentde-widgets`). Another extension adds widgets by depending on `AgentDEWidgets` and conforming to `WidgetProvider`:

```swift
import AgentDEKit
import AgentDEWidgets
import SwiftUI

extension HelloExtension: WidgetProvider {
    public var widgets: [WidgetDefinition] {
        [WidgetDefinition(id: "hello.clock", name: "Clock") {
            AnyView(WidgetCard { Text(Date.now, style: .time).font(.title) })
        }]
    }
}
```

| Piece | Use |
|---|---|
| `WidgetDefinition(id:name:view:)` | `id` is stable: it remembers which widget is shown; prefix it with your extension's id |
| `WidgetCard` | The plain frame text widgets share; fills the height the user dragged the widget to |
| `.widgetListHeight(_:)` | A scrolling list: up to the given height by itself, or the dragged height |
| `WidgetMessage(text:button:action:)` | An empty or setup state: a line of text and an optional button |
| `\.widgetHeight` | The dragged height, or nil for the natural height |

The menu lists widgets from every `WidgetProvider` in load order.

## Ticket providers

A workstream's tickets are tracker-neutral: a key (`ENG-123`), `owner/repo#12`, or a link to Linear, Jira, GitHub, GitLab or any https page. A `TicketProvider` looks them up so the panel can show state, priority and title.

| Member | What |
|---|---|
| `tracker` | Matches the tracker a ticket's link names: `linear`, `jira`, `github`, `gitlab` |
| `name` | Shown to the user |
| `isReady` | Signed in and able to look things up |
| `claims(identifier:)` | Whether to look up a ticket linked by key alone, with no tracker known |
| `lookUp(_:completion:)` | Looks tickets up; call back on the main thread with the `TicketInfo`s found |
| `myTickets(completion:)` | The user's own open tickets, for picking one to link |

`TicketInfo` carries `identifier`, `title`, `url`, and optionally `state`, `stateType`, `colorHex` and `priority` (1 urgent to 4 low, 0 none). `TicketRow` draws one. Return providers from `ticketProviders`; `agentde-linear` is a complete example.

## Link rules

A `LinkRule` makes matching links open in the tab's viewer instead of the browser, and (with the Workstreams extension) count as artifacts in the panel.

| Field | What |
|---|---|
| `pattern` | A regular expression matching the whole link |
| `marker` | Text every such link contains, for skipping text quickly (`"example.com/pages/"`) |
| `canonical` | Maps a link to one form per page (say, a raw link to its view page); nil when it names nothing. Default: the link itself |
| `openURL` | The address to load for a canonical link. Default: the link itself |
| `title` | A title from the link itself. Default: none |

Claude artifact links are built in.

## Themes and palettes

| Type | Fields |
|---|---|
| `ThemeDefinition` | `id`, `name`, `alwaysDark` (ignores the light/dark setting), optional `logo` (an image shown in place of the app icon while the theme is on), and `resolve: (dark) -> Theme` |
| `PaletteDefinition` | `id`, `name`, `colors`: eight group colors as `0xRRGGBB` |

`Theme` has `window`, `sidebar`, `text`, `secondary`, `muted`, `border`, `hover`, `selected` (SwiftUI colors), `terminalBackground`, `terminalForeground`, `terminalSelection` (`NSColor`s), and an optional `outline` that outlines the active tab and group. Views read the current theme from `@Environment(\.theme)`.

## JSON plugins

A plugin is a folder in `~/.config/agentde/plugins/` (a renamed build uses its own data folder) holding a `plugin.json`. Plugins are read once at launch, in folder-name order; one whose `plugin.json` doesn't parse is skipped and logged in the debug log. Every field but `name` is optional.

| Field | What |
|---|---|
| `name` | The plugin's name |
| `widgets` | Sidebar widgets (needs the Widgets extension), each `{id, name, page or command, every?}` |
| `widgets[].page` | An HTML file inside the plugin's folder, shown in a web view; it can read only its own folder |
| `widgets[].command` | A shell command, run with `zsh -lc` in the plugin's folder; its output is shown (at most 4 KB; stopped after 10 seconds) |
| `widgets[].every` | Seconds between runs of `command`, or reloads of `page`; at least 5. Without it, a command runs once each time the widget is shown |
| `links` | Viewer links, each `{pattern, marker}` (see [Link rules](#link-rules)) |
| `themes` | Each `{id, name, alwaysDark?, dark?, light?}`. `dark` and `light` map `Theme` field names to `"#RRGGBB"` or `"#RRGGBBAA"`; a missing field takes the Claude theme's color, and a missing `light` uses `dark` (and the other way round) |
| `palettes` | Each `{id, name, colors}`: colors as `"#RRGGBB"` |

A plugin widget's id in the menu is `plugin.<id>`. The example in [`examples/hello-plugin`](https://github.com/AgentDE/agentde/tree/main/examples/hello-plugin) adds a page widget, a command widget, a link rule, a theme and a palette:

```json
{
  "name": "Hello",
  "widgets": [
    { "id": "hello.page", "name": "Hello", "page": "widget.html" },
    { "id": "hello.disk", "name": "Disk", "command": "df -h / | tail -1 | awk '{print $4 \" free of \" $2}'", "every": 300 }
  ],
  "links": [
    { "pattern": "https://gist\\.github\\.com/[\\w-]+/[0-9a-f]{20,}", "marker": "gist.github.com/" }
  ],
  "themes": [
    { "id": "hello.dusk", "name": "Dusk (always dark)", "alwaysDark": true,
      "dark": { "window": "#1B1B2F", "sidebar": "#16162A", "text": "#ECEAF6", "...": "..." } }
  ],
  "palettes": [
    { "id": "hello.sea", "name": "Sea", "colors": ["#0B7285", "#1098AD", "#15AABF", "#3BC9DB", "#66D9E8", "#99E9F2", "#C5F6FA", "#495057"] }
  ]
}
```

To try it: `cp -R examples/hello-plugin ~/.config/agentde/plugins/hello`, restart AgentDE, and pick **Hello** in the sidebar widget's menu.
