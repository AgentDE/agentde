#!/bin/zsh
# Registers the `workstream` MCP server and its hooks for Claude Code (user scope) and Codex.
# Without --yes it only prints what it would change. Safe to run again: it changes only what's missing.
#
# Usage: scripts/register-workstream.sh [--yes]              register
#        scripts/register-workstream.sh --uninstall [--yes]  remove what this script added
#
# What it changes:
#   - Claude Code: `claude mcp add --scope user workstream -- <app>/Contents/MacOS/workstream-mcp`
#   - ~/.claude/settings.json: permissions.allow += "mcp__workstream__*"; hooks.SessionStart += one entry
#     (matcher startup|resume|compact → `workstream-mcp context`); hooks.UserPromptSubmit += one entry
#     (`workstream-mcp prompt-context`); hooks.SubagentStart += one entry (`workstream-mcp subagent-context`, so
#     sub-agents start with the workstream); an existing command status line is wrapped in
#     `workstream-mcp statusline -- '<command>'` (for the app's Stats; its output is unchanged). Existing
#     hooks are kept. A backup is written next to it first.
#   - ~/.codex/config.toml: a [mcp_servers.workstream] table.
# The server and hooks do nothing outside the app (see docs/WORKSTREAMS.md).
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

# WORKSTREAM_APP names the app whose server to register; else this build's (scripts/brand.sh).
source "${0:A:h}/brand.sh"
APP=${WORKSTREAM_APP:-/Applications/$APP_NAME.app}
[[ -d $APP || -n ${WORKSTREAM_APP:-} ]] || APP=$HOME/Applications/$APP_NAME.app
BIN=$APP/Contents/MacOS/workstream-mcp
if [[ $UNINSTALL == 0 && ! -x $BIN ]]; then
  echo "No $BIN. Install the app first." >&2
  exit 1
fi
SETTINGS=$HOME/.claude/settings.json
CODEX=$HOME/.codex/config.toml

say() { print -r -- "$@"; }
[[ $APPLY == 1 ]] || say "Dry run: nothing is changed. Run again with --yes to apply."

# 1. Claude Code MCP server (user scope).
current=$(claude mcp get workstream 2>/dev/null | sed -n 's/^ *Command: *//p' | head -1 || true)
if [[ $UNINSTALL == 1 ]]; then
  if [[ -n $current ]]; then
    say "Claude: remove the user-scope MCP server 'workstream' ($current)"
    [[ $APPLY == 1 ]] && claude mcp remove --scope user workstream >/dev/null
  fi
elif [[ $current != "$BIN" ]]; then
  [[ -n $current ]] && say "Claude: replace the MCP server 'workstream' ($current)"
  say "Claude: claude mcp add --scope user workstream -- $BIN"
  if [[ $APPLY == 1 ]]; then
    [[ -n $current ]] && claude mcp remove --scope user workstream >/dev/null 2>&1 || true
    claude mcp add --scope user workstream -- "$BIN" >/dev/null
  fi
fi

# 2. ~/.claude/settings.json: the allow rule and the two hooks.
python3 -I - "$SETTINGS" "$BIN" "$APPLY" "$UNINSTALL" <<'PY'
import json, os, shlex, shutil, sys
path, binary, apply, uninstall = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
settings = json.load(open(path)) if os.path.exists(path) else {}
before = json.dumps(settings, sort_keys=True)
rule = "mcp__workstream__*"
wanted = {
    "SessionStart": {"matcher": "startup|resume|compact",
                     "hooks": [{"type": "command", "command": f'"{binary}" context'}]},
    "UserPromptSubmit": {"hooks": [{"type": "command", "command": f'"{binary}" prompt-context'}]},
    "SubagentStart": {"hooks": [{"type": "command", "command": f'"{binary}" subagent-context'}]},
}
def ours(entry):
    """A hook entry this script added: one whose commands run workstream-mcp."""
    return any("workstream-mcp" in h.get("command", "") for h in entry.get("hooks", []))
allow = settings.setdefault("permissions", {}).setdefault("allow", [])
hooks = settings.setdefault("hooks", {})
if uninstall:
    if rule in allow:
        allow.remove(rule); print(f"settings.json: remove permissions.allow {rule}")
    for event in wanted:
        kept = [e for e in hooks.get(event, []) if not ours(e)]
        if len(kept) != len(hooks.get(event, [])):
            print(f"settings.json: remove the workstream {event} hook")
            hooks[event] = kept
else:
    if rule not in allow:
        allow.append(rule); print(f"settings.json: add permissions.allow {rule}")
    for event, entry in wanted.items():
        entries = hooks.setdefault(event, [])
        mine = [e for e in entries if ours(e)]
        if mine != [entry]:
            print(f"settings.json: {'update' if mine else 'add'} the {event} hook: {entry['hooks'][0]['command']}"
                  + (f" (matcher {entry['matcher']})" if 'matcher' in entry else ""))
            hooks[event] = [e for e in entries if not ours(e)] + [entry]
# The status line: your command runs inside `workstream-mcp statusline -- '<command>'`, which saves Claude's
# status input for the app's Stats and prints your command's output unchanged. Only an existing command
# status line is wrapped; uninstalling puts the original command back exactly.
wrapper = f'"{binary}" statusline -- '
line = settings.get("statusLine")
if isinstance(line, dict) and line.get("type") == "command" and isinstance(line.get("command"), str):
    command = line["command"]
    wrapped = "workstream-mcp\" statusline -- " in command
    if uninstall and wrapped:
        rest = command.split("statusline -- ", 1)[1]
        parts = shlex.split(rest)
        original = parts[0] if len(parts) == 1 else rest
        line["command"] = original
        print(f"settings.json: unwrap the status line, back to: {original}")
    elif not uninstall and not wrapped:
        line["command"] = wrapper + shlex.quote(command)
        print(f"settings.json: wrap the status line: {line['command']}")
    elif not uninstall and wrapped and not command.startswith(wrapper):
        # Wrapped by another copy of the app: point it at this one.
        line["command"] = wrapper + command.split("statusline -- ", 1)[1]
        print(f"settings.json: update the status line wrapper: {line['command']}")
# Uninstalling tidies away containers left empty; installing never removes anything.
if uninstall:
    for event in list(hooks):
        if not hooks[event]: del hooks[event]
    if not settings["permissions"]["allow"]: del settings["permissions"]["allow"]
    if not settings["permissions"]: del settings["permissions"]
    if not settings["hooks"]: del settings["hooks"]
else:
    if not settings["permissions"]["allow"]: del settings["permissions"]["allow"]
    if not settings["permissions"]: del settings["permissions"]
    if not settings["hooks"]: del settings["hooks"]
if json.dumps(settings, sort_keys=True) != before and apply:
    if os.path.exists(path): shutil.copy2(path, path + ".bak-workstream")
    tmp = path + ".tmp-workstream"
    with open(tmp, "w") as f: json.dump(settings, f, indent=2); f.write("\n")
    os.replace(tmp, path)
    print(f"settings.json: written (backup: {path}.bak-workstream)")
PY

# 3. Codex.
if [[ -f $CODEX ]] || [[ $UNINSTALL == 0 && -d ${CODEX:h} ]]; then
  python3 -I - "$CODEX" "$BIN" "$APPLY" "$UNINSTALL" <<'PY'
import os, re, shutil, sys
path, binary, apply, uninstall = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
text = open(path).read() if os.path.exists(path) else ""
table = re.compile(r'(?ms)^\[mcp_servers\.workstream\]\n.*?(?=^\[|\Z)')
block = f'[mcp_servers.workstream]\ncommand = "{binary}"\n'
found = table.search(text)
new = text
if uninstall:
    if found:
        new = table.sub("", text).rstrip("\n") + "\n"
        print("config.toml: remove [mcp_servers.workstream]")
elif not found:
    new = text.rstrip("\n") + ("\n\n" if text.strip() else "") + block
    print(f'config.toml: add [mcp_servers.workstream] command = "{binary}"')
elif found.group(0).strip() != block.strip():
    new = table.sub(block + "\n", text); print(f'config.toml: update [mcp_servers.workstream] to "{binary}"')
if new != text and apply:
    if os.path.exists(path): shutil.copy2(path, path + ".bak-workstream")
    with open(path + ".tmp-workstream", "w") as f: f.write(new)
    os.replace(path + ".tmp-workstream", path)
    print(f"config.toml: written (backup: {path}.bak-workstream)")
PY
fi
