# AgentDE. Everything builds with the Xcode Command Line Tools; see README.md.
# EXTENSIONS=path/to/extensions.json picks the native extensions (default extensions.json; scripts/assemble.py),
# and BRAND=path/to/brand.env builds a renamed app (scripts/brand.sh).
export EXTENSIONS BRAND
.PHONY: app debug test install uninstall run run-test icons signing register-workstream clean

app:            ## Build build/<app>.app (release)
	scripts/build-app.sh release

debug:          ## Build a debug app
	scripts/build-app.sh debug

test:           ## Run the core's tests (each extension has its own)
	scripts/test.sh

install: test   ## Test, build and install to /Applications plus a launcher command
	scripts/install.sh

uninstall:      ## Remove the installed app and command (keeps your saved state)
	scripts/install.sh --uninstall

run: app        ## Build and open the app
	open build/*.app

run-test: app   ## Run a second copy with its own state, leaving yours alone
	scripts/run-test-instance.sh

register-workstream: ## Show (then, with YES=1, apply) the workstream MCP server and hooks for Claude Code and Codex
	scripts/register-workstream.sh $(if $(YES),--yes,)

signing:        ## One-time: create a local signing identity so macOS keeps permissions across rebuilds
	scripts/setup-signing.sh

icons:          ## Redraw the AgentDE icon (Resources/AppIcons/agentde.png, AppIcon.icns)
	scripts/make-icon.sh

clean:          ## Remove build output
	rm -rf .build build dist

