#!/bin/zsh
# Gives Codex tabs a status dot: adds hooks to ~/.codex/hooks.json that report working, needs-you and idle to
# AgentDE through $AGENTDE_STATUS_FILE (see "Agent status" in docs/GUIDE.md). Outside AgentDE they do nothing.
# Without --yes it only prints what it would change. Safe to run again. A backup is written next to the file.
#
# Usage: scripts/register-agent-status.sh [--yes]              register
#        scripts/register-agent-status.sh --uninstall [--yes]  remove what this script added
#
# Codex runs a new or changed hook only after you trust it: run /hooks in Codex once afterwards.
set -euo pipefail

APPLY=0
UNINSTALL=0
for arg in "$@"; do
  case $arg in
    --yes) APPLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "usage: $0 [--uninstall] [--yes]" >&2; exit 2 ;;
  esac
done

HOOKS=${CODEX_HOME:-$HOME/.codex}/hooks.json
if [[ ! -d ${HOOKS:h} ]]; then
  echo "No Codex folder at ${HOOKS:h}; nothing to do."
  exit 0
fi

python3 -I - "$HOOKS" "$APPLY" "$UNINSTALL" <<'PY'
import json, os, shutil, sys
path, apply, uninstall = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"

# The same command as HookStatus.hookCommand in the app (a test keeps them equal).
def command(state):
    return ('cat >/dev/null 2>&1; [ -n "${AGENTDE_STATUS_FILE-}" ] && printf \'%s %s\\n\' ' + state
            + ' "$PPID" > "$AGENTDE_STATUS_FILE" 2>/dev/null; exit 0')

WANTED = {"SessionStart": "idle", "UserPromptSubmit": "working", "PostToolUse": "working",
          "PermissionRequest": "needs-you", "Stop": "idle"}

def ours(entry):
    return any("AGENTDE_STATUS_FILE" in h.get("command", "") for h in entry.get("hooks", []))

config = {}
if os.path.exists(path):
    with open(path) as f:
        config = json.load(f)
hooks = config.setdefault("hooks", {})
changes = []
for event, state in WANTED.items():
    entries = hooks.get(event, [])
    kept = [e for e in entries if not ours(e)]
    if uninstall:
        if len(kept) != len(entries):
            changes.append(f"remove the AgentDE status hook from {event}")
        hooks[event] = kept
    else:
        entry = {"hooks": [{"type": "command", "command": command(state), "timeout": 5}]}
        if entry not in entries:
            changes.append(f"{'update' if len(kept) != len(entries) else 'add'} the {event} hook: report {state}")
            hooks[event] = kept + [entry]
for event in list(hooks):
    if not hooks[event]:
        del hooks[event]
if not hooks:
    del config["hooks"]

if not changes:
    print(f"{path}: nothing to change.")
    sys.exit(0)
for change in changes:
    print(f"{path}: {change}")
if not apply:
    print("Dry run: run again with --yes to apply.")
    sys.exit(0)
if os.path.exists(path):
    shutil.copy2(path, path + ".bak-agentde")
with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
print("Done. In Codex, run /hooks once to trust the new hooks.")
PY
