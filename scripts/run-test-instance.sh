#!/bin/zsh
# Starts a second copy of the built app with its own state file, leaving your real install alone.
# Usage: scripts/run-test-instance.sh [state-dir]   (default: a fresh temporary folder)
set -euo pipefail
cd "${0:A:h}/.."
source scripts/brand.sh
[[ -x build/$APP_NAME.app/Contents/MacOS/$APP_NAME ]] || scripts/build-app.sh
DIR=${1:-$(mktemp -d)}
mkdir -p "$DIR"
echo "Test instance state: $DIR/state.json (logs: $DIR/logs, transcript cache: $DIR/cache). Quit it with ⌘Q."
AGENTDE_STATE="$DIR/state.json" AGENTDE_LOG_DIR="$DIR/logs" WORKSTREAM_CACHE_DIR="$DIR/cache" "build/$APP_NAME.app/Contents/MacOS/$APP_NAME"
