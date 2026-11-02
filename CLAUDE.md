# AgentDE: notes for agents

Native macOS app (SwiftUI + AppKit) that hosts terminal agents in groups and tabs, with a minimal core and native extensions. Read `docs/ARCHITECTURE.md` before any substantial change, and `docs/EXTENDING.md` before touching the extension API.

## Build and test

- `make` builds `build/AgentDE.app` with the extensions in `extensions.json` (side by side; missing ones are cloned from their `repo`), `make test` runs the core's Swift Testing suites, and `make install` tests, builds and installs. Plain `swift build` / `swift test` fail on SDKs whose SwiftUI needs Xcode's macro plugins; the scripts set `SDKROOT` from `scripts/env.sh`.
- Add tests in `Tests/AgentDETests/` for new logic that doesn't need a window. Keep such logic in plain functions, and inject folders or paths (see `TranscriptIndex(projectsDir:)`) rather than reaching into `~`.
- Bump `VERSION` for user-visible releases; the build number is the commit count.
- There's no Xcode. Don't add anything that needs it: `.metal` files to process, asset catalogs, SwiftUI macros like `#Preview` or `@Entry`, or Xcode project files.
- Use `AppBrand.name` for the app's name in anything users see, and `AppBrand.configDirectory` for its folder: a brand file can rename the build (`scripts/brand.sh`).

## Conventions

- The core is `Sources/AgentDE/<area>/`; the extension API and the views extensions share are `Sources/AgentDEKit/`. Features that only some users want belong in an extension, reached through a hook in `AgentDEKit/Extension.swift`, not in the core.
- All state changes go through `Store` methods, and they call `scheduleSave()` when saved data changes.
- New saved fields on `GroupModel` and `TabModel` must be optional, and new settings need defaults. Old state files must keep loading. Extensions keep their data with `AgentDEHost.value`/`setValue` and `settings`/`saveSettings`.
- Terminal and web views are owned by registries, never by SwiftUI. Don't create `TerminalSession` or `WKWebView` inside view bodies.
- Animations that loop belong in Core Animation (see `StatusDot`), not SwiftUI `repeatForever`, to keep idle CPU near zero.
- Changes to `Vendor/SwiftTerm` must be recorded in `Vendor/SwiftTerm/PATCHES.md`.
- Keep `README.md` (user-facing: features, keys, settings), `docs/ARCHITECTURE.md` (internals) and `docs/EXTENDING.md` (the API) current when behavior changes.

## Testing changes

- After building, check that the app launches: `open build/AgentDE.app`, then `pgrep -lf AgentDE.app`. Check memory and idle CPU with `ps -o rss=` and `top -l 2 -pid <pid> -stats cpu`.
- Don't quit or kill a running AgentDE without asking the user. Their tabs keep running in `agentde-pty` holders when the app quits. Never kill the user's holders (sockets in `~/.config/<data folder>/pty/`): that ends a tab's shell and agent. A test instance's holders live in their own folder, named by the hash of its state path; clean up only those.
- `scripts/register-workstream.sh` edits the user's global Claude Code and Codex config. Its dry run (no `--yes`) is fine; apply it only when the user asks.
- Saved state is in `~/.config/<data folder>/state.json`. Inspect it read-only. To try something in a real window, `make run-test` runs a second copy with its own state and log folder; quit it when you're done.
- Debugging: `~/Library/Logs/<app name>/agentde.log` (events and the per-minute heartbeat) and `hang-*.txt` (stack samples of main-thread stalls).
