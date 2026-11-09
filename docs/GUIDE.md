# AgentDE guide

Everything AgentDE does, and every key and setting. The [README](https://github.com/AgentDE/agentde#readme) is the short version.

**Contents:** [Install](#install) · [The basics](#the-basics) · [Extensions](#extensions) · [Plugins](#plugins) · [File Explorer](#file-explorer) · [Search](#search) · [Recent sessions](#recent-sessions) · [Startup command](#startup-command-conda-and-friends) · [Forking](#forking-a-claude-session) · [Agent status](#agent-status) · [Pull requests](#pull-requests) · [Restoring](#restoring) · [Keys](#keys) · [Settings](#settings) · [Files](#files) · [Troubleshooting](#troubleshooting) · [Building](#building) · [Development](#development) · [License](#license)

How it works inside: [ARCHITECTURE.md](ARCHITECTURE.md). Writing extensions and plugins: [EXTENDING.md](EXTENDING.md). Notes for agents working on this repo: [CLAUDE.md](https://github.com/AgentDE/agentde/blob/main/CLAUDE.md).

## Install

Clone this repo, then (the first build clones the extensions in `extensions.json` next to it; see [Extensions](#extensions)):

```bash
cd agentde
make signing        # once: a local signing identity, so macOS keeps your permission answers across builds
make install        # test, build, install to /Applications, and add an `agentde` command
```

Open AgentDE like any app, or run `agentde` from any terminal. Run `make install` again to update: it replaces the installed app, and a running copy keeps working until you restart it (**Update installed · Restart** in the status bar). Restarting keeps every tab running. `make uninstall` removes the app and the command, and keeps your saved state.

| Requirement | Notes |
|---|---|
| macOS 14 or later | |
| Xcode Command Line Tools | `xcode-select --install`; full Xcode isn't needed |
| `claude` on your login shell's `PATH` | For Claude tabs; `codex` for Codex tabs |

**Why `make signing`.** macOS ties privacy permissions (Documents, Downloads, Desktop and so on) to an app's code signature, and terminals inherit AgentDE's. An ad hoc signature changes with every build, so macOS would ask again after each install. `make signing` creates a self-signed identity, "AgentDE Local Signing", in your login keychain, usable only for code signing; builds use it automatically. `scripts/setup-signing.sh --remove` deletes it.

## The basics

**Groups.** A group has a name, a color and a folder. New tabs in the group open in that folder. Create one with ⌘⇧N or **+ New group** in the sidebar. Double-click a group to rename it. Right-click it to open a new tab of any kind (plus anything extensions add to **New**), change its color, set its startup command, collapse it, reveal its folder or delete it.

**Tabs.** A tab is a terminal running one of these:

| Kind | Starts with | New tab |
|---|---|---|
| Claude | `claude` (drops to your shell when Claude exits) | ⌘T |
| Shell | your login shell | ⌘⇧T |
| Codex | `codex` (drops to your shell when Codex exits) | ⌘⌥T |
| Diff | `git diff` piped through `less`; closes when you quit `less` | ⌘⇧D |
| Files | The File Explorer: a folder tree with previews | ⌘⇧E |

The **+** after the last tab opens a new tab of any kind. Closing a tab's process (`exit`, or quitting Claude and then the shell) closes the tab. A Claude tab is named after its Claude session; rename it with ⌘R or a double-click. Starting Claude in a shell tab turns it into a Claude tab.

**The sidebar** lists every group with its tabs. Click the chevron to collapse or expand a group; ⌥-click to do all of them. Collapsing is saved, and collapsed groups show status dots next to the name.

**Icons** show a short label when you hover over them.

**Opening files and links from the terminal.** ⌘-click a file path or URL in any tab; holding ⌘ underlines what's clickable.

| Link | Opens in |
|---|---|
| Files and local pages (`localhost`, `127.0.0.1`) | The tab's **viewer**, above the chat |
| Claude artifact links, and links an extension or plugin claims | The viewer |
| Folders | A new **File Explorer** tab, rooted there |
| Other web links | Your browser |
| ⌥⌘-click on a file or local page | Its default app |

The **viewer** shows Markdown as a document, local HTML, PDFs, images, video and audio, diffs, code and text, and anything else through Quick Look. It refreshes when the file changes, except a Quick Look preview, which ↻ refreshes. ↻ reloads, the copy button copies the path or link, **Raw** shows a Markdown file's text, **Open in browser** hands a web page to your browser. Links in a local HTML page open in the viewer too (another file or a web page; folders go to Finder). Images fit the viewer and zoom: pinch, double-click to switch between fit and actual size, or click the image and use ⌘+ / ⌘− / ⌘0 (fit). Drag the divider to resize it; ⤢ fills the tab; × (or Esc, after clicking into it) closes it. Sign-ins inside the viewer are remembered.

**Recent in the viewer.** Each tab remembers the last 10 files and pages its viewer showed. Click the viewer's title for the list, newest first, and pick one to show it again (**Forget** drops one). ‹ and › in the viewer's header (or ⌘[ and ⌘]) go back and forward through it; following a link after going back drops what was ahead, as in a browser; with the viewer closed, ⌘[ or the clock button beside the tab strip's + reopens the last one.

**`open` in a tab.** `open report.html` or `open https://…` in a tab shows the file or page in that tab's viewer, and so does `! open …` in Claude, or Claude running `open` itself. Anything else (options like `-a`, several items, folders, apps) goes to macOS's own `open`, and `/usr/bin/open` always does. So does a web page that a program opens (a CLI's sign-in, such as `databricks auth login`) and any sign-in link: those need your browser. Turn it off in Settings → Terminal; it applies to tabs opened after the change.

**Paths:** relative paths are found in the tab's folder, then the group's, and a `:line:col` suffix is fine. Punctuation right after a path is ignored. A path written from a subfolder, or a bare file name, is found with a Spotlight search of the tab's and group's folders; if several match, the most recently changed opens. AgentDE sets `FORCE_HYPERLINK=1`, so Claude Code prints its paths as proper links.

**Browser above a tab.** ⌘⇧B adds a small browser pane above the active tab. The address bar accepts `5173` or `:5173` for `http://localhost:5173`, a path like `~/report.html`, or any URL. Each tab remembers its last URL.

**Side panel.** An extension can add a panel beside an agent tab's chat (the Workstreams extension does). Layout → Side Panel (⌥⌘I) hides or shows it for the tab.

## Extensions

An **extension** is a Swift package, built into the app, that adds features through the hooks in `Sources/AgentDEKit/Extension.swift`. `extensions.json` lists the ones a build includes:

| Extension | Repo | Adds |
|---|---|---|
| Widgets | `agentde-widgets` | The sidebar widget spot and its menu, the Calendar widget, JSON plugins' widgets |
| Workstreams | `agentde-workstreams` | The workstream panel beside each agent's chat, New → Workstream… (a git worktree per piece of work), the Usage widget; bundles the `workstream` MCP server from `workstream-mcp` |
| Linear | `agentde-linear` | Linear ticket lookups for workstreams, and the Linear widget |

Each repo's README has its features and settings.

**Side by side.** Extensions are path dependencies. The build clones any that are missing (and the packages they depend on) next to this repo, from the `repo` each entry names:

```
agentde/                (this repo)
agentde-widgets/
agentde-workstreams/
agentde-linear/
workstream-mcp/         (used by agentde-workstreams)
```

**Adding or removing one.** Edit `extensions.json` (or point `EXTENSIONS=` at another file) and rebuild. Each entry names the package folder (relative to the file), the repo to clone it from when it isn't there, its library product, the expression that creates the extension, and any helper executables to bundle:

```json
{ "package": "../agentde-linear", "repo": "https://github.com/AgentDE/agentde-linear",
  "product": "AgentDELinear", "create": "LinearExtension()" }
```

An empty list builds the core alone. Order matters where extensions compete for one slot (the side panel, the sidebar footer): the first that fills it wins. Settings → Extensions shows each loaded extension's own settings. How to write one: [docs/EXTENDING.md](EXTENDING.md).

## Plugins

A **JSON plugin** is a folder in `~/.config/agentde/plugins/` with a `plugin.json`. It can add sidebar widgets (an HTML page, or a shell command's output), links that open in the viewer, themes and group palettes, with nothing to build. Plugins are read at launch, so restart AgentDE after changing one. Widgets need the Widgets extension. An example is in [examples/hello-plugin](examples/hello-plugin); the format is in [docs/EXTENDING.md](EXTENDING.md#json-plugins).

## File Explorer

**⌘⇧E** opens a File Explorer tab on the group's folder (or the active tab's folder); so does right-click on a group → **New → File Explorer**. It's for looking, not editing.

- **Tree:** folders load as you open them. Dotfiles show. Generated folders like `.git`, `node_modules`, `__pycache__` and `.venv` are hidden; the eye button shows them. ↑↓ move, → and ← open and close folders, Return opens a file in its default app.
- **Find a file:** type in the box at the top to search the whole folder by path. In a git repo it uses `git ls-files`, so it respects `.gitignore`. Every word must appear; matches in the file name rank first.
- **Preview:** the right side shows the selected file with Quick Look. Buttons open it in the default app or Cursor, or reveal it in Finder.
- **Right-click a file:** open it, open it in Cursor, reveal it in Finder, show an HTML file in the tab's browser pane, copy its full or relative path, or **Send path to Claude**, which types the relative path into the group's most recently used Claude tab, without pressing Return, and switches to it.

The selected file is remembered across relaunches.

## Search

**⌘⇧F searches across your sessions.** It covers every open tab:
- **Claude tabs:** the session's whole conversation (your prompts and Claude's replies), including history that scrolled out of the terminal or was compacted away. Tool output isn't searched.
- **Shell tabs:** the terminal's scrollback.

Tick **Include recent sessions** to also search each group's Recent list.

Every word must appear, in any order, ignoring case. Results stream in per session, newest first, with matches highlighted. ↑↓ and Return, or a click, jumps there: a tab is selected and scrolls to the latest occurrence; a recent session is resumed in a new tab. The first search reads each transcript once, which can take several seconds; later searches read only what's new.

**⌘F finds within the current tab's terminal**, with ⌘G and ⌘⇧G for next and previous. With the viewer focused or filling the tab, ⌘F searches the viewer instead.

## Recent sessions

Under each group's tabs, a faded **Recent** list shows the named sessions you started in exactly that group's folder in the last 2 weeks. Click one to resume it in a new tab: Claude with `claude --resume`, Codex with `codex resume`.

- **Only yours, only named.** Claude sessions count if you started them from the CLI or the desktop app and gave them a title (`/rename`, or the desktop app's), or Claude Code named a background session. Codex threads count if you started and named them in the Codex CLI or desktop app. SDK runs, forks, `codex exec` runs, sub-agent threads and sessions already open in a tab are left out.
- **Telling them apart.** Codex sessions show the Codex icon. A Claude session live in another terminal shows a radio-waves icon, and AgentDE asks before opening a second copy.
- **Hiding it.** Click **Recent** to fold the list (remembered per group), right-click the group → **Hide recent sessions**, or turn it off in Settings → Terminal, where you can also leave Codex out and change the number of days.
- **Older.** **Older** unfolds the group's named sessions from before that (as far back as Claude and Codex keep transcripts: Claude Code deletes them after 30 days unless `cleanupPeriodDays` in `~/.claude/settings.json` says otherwise). It shows under any group that has older sessions, with their count, even when Recent is empty; they're scanned in the background shortly after launch.
- **Pinned.** Right-click a session, or an open Claude or Codex tab, → **Pin to Top**. A pinned tab moves to the top of its group with a pin; once closed, its session stays at the top of the group's session list, whatever its age. Right-click → **Unpin** to take it back. Pins are saved with the group.

The list refreshes every 30 seconds.

## Startup command (conda and friends)

Set **Settings → Terminal → Startup command** to something like `conda activate myenv`, and every new tab runs it before Claude or Codex starts. Override it per group with right-click → **Startup command…**: empty uses the default, `:` runs nothing.

Tabs run a normal interactive login zsh with your dotfiles. The startup command and the agent run in that shell, so when the agent exits you're back at the same prompt with the environment still set up. History goes to your usual `~/.zsh_history`.

## Forking a Claude session

- **Type `/fork` in Claude.** Claude copies the conversation into a new background session and keeps working in the current tab. AgentDE opens the new session as a tab after the last tab you used in that folder, running `claude attach <id>`. The fork keeps running whether or not its tab is open. Any other named background session in a group's folder (say, from `claude --bg`) opens the same way.
- **Or press ⌘⌥F** (also in the tab's right-click menu and ⌘K): forks the active tab's conversation into a new interactive tab with `claude --resume <id> --fork-session`.

A fork is an independent tab: renaming or closing either one doesn't affect the other.

## Agent status

AgentDE reads Claude Code's registry of running sessions (`~/.claude/sessions/`) once a second and matches each session to its tab. Nothing needs configuring.

| Dot | Means |
|---|---|
| Green, breathing | Claude is working on a turn |
| Amber, pulsing | Claude is waiting on you, for example a permission prompt |
| Blue | A turn finished while you were looking elsewhere; clears when you view the tab |
| Icon only | Idle, or no agent running |

- **Sparkle:** a turn of 45 seconds or more ends with a small sparkle (adjustable in Settings → Fun).
- **Dock badge:** how many tabs are waiting on you. **⌘J** jumps to the next waiting tab, then to finished ones. **⌘K** with an empty query lists tabs by urgency.
- **Why it's waiting:** when Claude reports it, in the tab's tooltip, the status bar and ⌘K.
- **Notifications:** a macOS banner when an agent needs you, or finishes while you're elsewhere; a click brings AgentDE forward on that tab. Turn either, or the sound, off in Settings → Agents.
- **Bell:** a terminal bell in a tab you're not looking at marks it amber.

Codex tabs don't show status.

## Pull requests

The header shows the group's name and folder (then the tab's folder, when the tab is in a subfolder or worktree: `app › ql-crash`), the branch, and the branch's open PR: its number and a summary of checks (✓ passing, a clock while running, ✗ failing). Click it to open the PR on GitHub, or Graphite (Settings → Agents). When checks fail and Claude is idle, **Fix with Claude** types a prompt naming the failing checks and the `gh run view … --log-failed` commands for their logs, and asks Claude to explain before pushing.

PR info comes from `gh pr view` (the GitHub CLI, logged in), at most once a minute, and only for the tab you're looking at.

## Restoring

**Quitting, updating or a crash never stops anything.** Every tab's shell runs in its own small holder process (`agentde-pty`), not inside AgentDE. On the next launch each tab reconnects to its holder and shows the screen as it is now.

| Case | What happens |
|---|---|
| Updating | `make install`, then **Update installed · Restart** in the status bar, or **AgentDE → Restart AgentDE** at any time |
| Scrollback after a restart | The last 2 MB or so of each tab's output is replayed |
| After a reboot | Holders are gone; Claude tabs resume their session with `claude --resume <id>` |
| Tabs with nothing running | Start lazily, the first time you view them; until then they show a moon icon and the session's last name |

Quitting saves groups, tabs, colors, names, browser URLs and settings. Closing a tab is the way to end what runs in it.

### Background mode

Turn on **Settings → Agents → Run Claude as background sessions**. New Claude tabs then start as Claude background sessions (`claude --bg`) and attach with `claude attach <id>`. Closing a tab stops its agent (`claude stop`); the conversation is kept, so you can resume it from Recent. To close the tab and leave the agent working, right-click it → **Close, keep agent running**; reattach from Claude's Agent View (⌘K → **Open Agent View**).

Background sessions inherit your startup command's environment, but Claude's background service reorders `PATH`, so a conda env's `python` may not come first.

## Keys

| Key | Action |
|---|---|
| ⌘T, ⌘⇧T, ⌘⌥T | New Claude, shell or Codex tab |
| ⌘⇧E | New File Explorer tab |
| ⌘W | Close tab (asks if its agent is working) |
| ⌘R, or double-click | Rename tab |
| ⌘⇧F | Search all sessions |
| ⌘F, ⌘G, ⌘⇧G | Find in this tab (or its viewer, when focused), next, previous |
| ⌘⌥F | Fork the tab's Claude session into a new tab |
| ⌘1 … ⌘9 | Go to tab 1–8, or the last tab |
| ⌘⇧[, ⌘⇧] | Previous or next tab |
| ⌘⌥↑, ⌘⌥↓ | Previous or next group |
| ⌘K | Jump to any tab or group, or run an action |
| ⌘J | Next tab that needs you, then finished ones |
| ⌘-click, ⌥⌘-click | Open a path or link from the terminal (in the viewer / in its default app) |
| ⌥⌘I | Show or hide the side panel |
| ⌘⇧B | Browser above the tab |
| ⌘[, ⌘] | Viewer: back and forward through what it showed (⌘[ reopens a closed viewer) |
| ⌘⇧D | Diff of the tab's folder |
| ⌘⇧O | Open the tab's folder in Cursor |
| ⌘⇧N | New group |
| ⌘0 | Show or hide the sidebar |
| ⌘=, ⌘- | Bigger or smaller terminal text |
| ⌘, | Settings |

**Mouse:** drag tabs to reorder them, or onto a sidebar group to move them. Drag groups to reorder them. Right-click tabs and groups for everything else. Double-click the header to zoom the window.

## Settings

Open with ⌘, or the sliders icon at the bottom of the sidebar.

| Tab | Options |
|---|---|
| Look | Light, dark or match system; theme (Claude warm, Graphite cool, Midnight, High contrast, plus extensions' and plugins'); group colors (Soft, Vivid, Pastel, plus extensions' and plugins'); translucent sidebar; density; tabs on top or bottom; sidebar width |
| Terminal | Font, size, GPU rendering (experimental, off by default), scrollback (default 10,000 lines), startup command, recent sessions (on/off, Codex too, how many days), what kind of tab new tabs start as, `open` shows files and pages in the viewer |
| Fun | Animated status dots, the finish sparkle, and how long a turn must run to earn one |
| Agents | Notifications (needs you, done, sound), background mode, PR status (on/off, open in GitHub or Graphite) |
| Extensions | Each loaded extension's own settings |
| Icon | The Dock icon; shown only when the build ships more than one |

## Files

| Path | What |
|---|---|
| `~/.config/agentde/state.json` | Everything AgentDE saves ([format](ARCHITECTURE.md#saved-state)) |
| `~/.config/agentde/zsh/` | Shell-integration wrappers, rewritten at every launch |
| `~/.config/agentde/pty/` | Terminal holders' sockets |
| `~/.config/agentde/plugins/` | JSON plugins |
| `~/Library/Logs/AgentDE/agentde.log` | Debug log; hang samples beside it |
| `~/.claude/sessions/*.json` | Claude Code's live session registry, read-only |
| `~/.claude/state/rate_limits.json` | Optional. If your status line script writes it, the status bar shows 5-hour and 7-day usage |

A renamed build (see [Building](#building)) uses its own folder names in place of `agentde` and `AgentDE`.

Each tab's environment includes `TERM_PROGRAM=AgentDE` and `AGENTDE_TAB_ID=<uuid>`, so scripts and hooks can tell where they run. Extensions can add more (the Workstreams extension adds `WORKSTREAM_TAB_ID` and `WORKSTREAM_ID`).

## Troubleshooting

| Problem | Fix |
|---|---|
| macOS keeps asking for permissions after updates | Run `make signing` once, then `make install`. Or give AgentDE **Full Disk Access** in System Settings → Privacy & Security |
| A Claude tab says `claude: command not found` | Tabs run your login shell (`zsh -l`), so `claude` must be on the `PATH` your `.zprofile` or `.zshrc` sets |
| Status dots never appear | Check that `~/.claude/sessions/` has a JSON file for the running session; older Claude Code versions don't write it |
| Hard to see what's active | Settings → Look → High contrast: black and white with orange outlines on the active tab and group |
| Slow or spinning while agents work | Keep **GPU rendering** off (Settings → Terminal) |
| Tabs or groups missing after an update | Unreadable parts of the saved state are dropped one by one, and the original is kept as `state.json.unreadable-<time>`; the debug log says what was dropped |
| `make` stops with "No package at …" or "Couldn't clone …" | An extension in `extensions.json` isn't beside this repo and couldn't be cloned: check its `repo` and your network, clone it yourself, or take it out of the file |
| Starting fresh | Quit, delete `~/.config/agentde/state.json`, reopen |

**Debug log.** Help → **Open Debug Log** opens `~/Library/Logs/AgentDE/agentde.log`: launches and quits, tabs starting and exiting, agent state changes, failed lookups, and a once-a-minute heartbeat with memory, CPU and any tab producing heavy output.

**Beachballs.** A watchdog notes any time the main thread is unresponsive for 2 seconds or more and saves a 3-second stack sample (`hang-<time>.txt`, at most one every 5 minutes, newest 10 kept). Help → **Show Logs and Hang Samples in Finder** gets you there.

## Building

```bash
make                 # build build/AgentDE.app (release) with the extensions in extensions.json
make install         # test, build, install to /Applications (or ~/Applications) and add a launcher in ~/.local/bin
```

| Variable | Does |
|---|---|
| `EXTENSIONS=path/to/extensions.json` | Builds with another list of extensions (default `extensions.json`) |
| `BRAND=path/to/brand.env` | Builds a renamed app that installs beside AgentDE with its own state, holders, logs and Keychain items |
| `AGENTDE_SDK=/path/to/sdk` | Builds against another SDK (default: the Command Line Tools' macOS 26 SDK) |

A brand file is a zsh file that may set these (defaults in brackets):

| Key | What |
|---|---|
| `APP_NAME` | The app's name, also its launcher command in lowercase [AgentDE] |
| `BUNDLE_ID` | [dev.agentde.AgentDE] |
| `DATA_FOLDER` | Folder under `~/.config` [agentde] |
| `DEFAULT_ICON` | The icon id used until Settings picks another [agentde] |
| `ICON` | The bundle's `.icns` [Resources/AppIcon.icns] |
| `BRAND_RESOURCES` | A folder whose contents join the bundle's Resources: more icons, files its extensions read |
| `SIGN_ID` | A code-signing identity; `-` signs ad hoc [AgentDE Local Signing if it exists, else ad hoc] |

**App icons.** Settings → Icon offers every PNG in the bundle's `Resources/AppIcons/`; an optional `AppIcons/icons.json` (`{"order": [ids], "names": {id: name}}`) sets their order and names. A brand adds icons through `BRAND_RESOURCES`.

## Development

```bash
make test       # run the core's tests (each extension has its own)
make run        # build and open the app
make run-test   # run a second copy with its own state and logs, leaving yours alone
make debug      # build a debug app
make icons      # redraw the AgentDE icon
make register-workstream   # show (YES=1 applies) the workstream MCP server and hooks for Claude Code and Codex
```

The version is in `VERSION`; the build number is the commit count.

```
Sources/AgentDE/      the core: App/ Model/ Store/ Terminal/ Agents/ Search/ Views/
Sources/AgentDEKit/   the extension API, and the theme, views and helpers extensions share
Sources/agentde-pty/  the terminal holder (C)
Tests/AgentDETests/
Vendor/SwiftTerm/     the terminal emulator (MIT), with local changes in PATCHES.md
Resources/            app icon
scripts/              build, assemble, brand, install, test, signing, icon and test-instance scripts
examples/             a JSON plugin
docs/                 ARCHITECTURE.md, EXTENDING.md
```

Read [docs/ARCHITECTURE.md](ARCHITECTURE.md) before changing anything substantial, especially the build notes about SDKs and the vendored terminal library.

## License

MIT; see [LICENSE](https://github.com/AgentDE/agentde/blob/main/LICENSE). Vendored SwiftTerm is MIT-licensed; see `Vendor/SwiftTerm/LICENSE`.
