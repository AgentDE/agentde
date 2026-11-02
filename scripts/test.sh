#!/bin/zsh
# Runs the test suite (Swift Testing, works with just the Command Line Tools).
set -euo pipefail
cd "${0:A:h}/.."
source scripts/env.sh
# With only the Command Line Tools, SwiftPM sometimes drops the Swift Testing macro plugin from incremental
# test builds ("plugin for module 'TestingMacros' not found"), so pass its folder explicitly.
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
# Tests log to a scratch folder, never the real log (DebugLog reads this once, at its first line).
export AGENTDE_LOG_DIR="${TMPDIR:-/tmp}/agentde-test-logs"
swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
