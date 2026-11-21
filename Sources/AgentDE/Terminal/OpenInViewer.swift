import Foundation

/// `open <file or web page>` in a tab shows it in that tab's viewer. Tabs get a small `open` script first on
/// their PATH, and Claude's Bash tool gets the same PATH through `CLAUDE_ENV_FILE` (its own commands run in a
/// fresh login shell, where macOS's path_helper would otherwise put /usr/bin/open first). The script leaves a
/// request in `requests`, which `AgentMonitor` hands to the tab within a poll. Anything else (options, several
/// items, folders, apps, or a shell outside a tab) goes to macOS's own `open`.
enum OpenInViewer {
    static let config = URL(fileURLWithPath: AppBrand.configDirectory)
    static let binDirectory = config.appendingPathComponent("bin")
    static let requests = config.appendingPathComponent("open")
    static let claudeEnvDirectory = config.appendingPathComponent("claude-env")

    /// The script, for a requests folder. `AGENTDE_REAL_OPEN` names the fallback (tests point it elsewhere).
    static func script(requests: URL) -> String {
        """
        #!/bin/sh
        # Written by \(AppBrand.name) at launch; edits are overwritten. In a tab, `open <file or web page>` shows it in
        # the tab's viewer; anything else goes to macOS's open. `/usr/bin/open` always reaches the real one.
        # A web page goes to the viewer only when a shell ran open: a program opening one (a CLI's sign-in, say)
        # gets the browser, and so does any sign-in link. When an agent (claude, codex) ran that shell, only a
        # local page goes to the viewer: the viewer shares your sign-ins, so other sites open in the browser.
        if [ -n "${AGENTDE_TAB_ID-}" ] && [ "$#" -eq 1 ]; then
          parent=$(ps -o comm= -p "$PPID" 2>/dev/null); parent=${parent##*/}; parent=${parent#-}
          case "$1" in
            -*) ;;
            *redirect_uri=*|*code_challenge=*|*/oauth*|*/authorize*) ;;
            http://*|https://*)
              case "$parent" in
                sh|bash|zsh|dash|ksh|fish)
                  case "$1" in
                    http://localhost*|https://localhost*|http://127.0.0.1*|https://127.0.0.1*|http://0.0.0.0*|http://\\[::1\\]*|*.localhost|*.localhost:*|*.localhost/*) item=$1 ;;
                    *)
                      agent=; p=$PPID; i=0
                      while [ "$i" -lt 16 ] && [ -n "$p" ] && [ "$p" -gt 1 ]; do
                        c=$(ps -o comm= -p "$p" 2>/dev/null); c=${c##*/}
                        # Up to the tab's holder: what's above it isn't the tab's.
                        case "$c" in claude|codex) agent=1; break ;; agentde-pty) break ;; esac
                        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i + 1))
                      done
                      [ -z "$agent" ] && item=$1 ;;
                  esac ;;
              esac ;;
            /*) [ -f "$1" ] && item=$1 ;;
            *) [ -f "$1" ] && item="$PWD/$1" ;;
          esac
          if [ -n "${item-}" ]; then
            dir=\(TerminalSession.shellQuoted(requests.path))
            name="$AGENTDE_TAB_ID.$$"
            mkdir -p "$dir" && printf '%s\\n' "$item" > "$dir/.$name" && mv "$dir/.$name" "$dir/$name" && exit 0
          fi
        fi
        exec "${AGENTDE_REAL_OPEN:-/usr/bin/open}" "$@"

        """
    }

    /// Writes the script; runs at launch with the shell integration.
    static func install() {
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let url = binDirectory.appendingPathComponent("open")
        try? script(requests: requests).write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The line Claude's Bash tool sources: the script's folder first on PATH, quoted so any folder name works.
    static func claudeEnvFile(bin: String) -> String {
        "export PATH=" + TerminalSession.shellQuoted(bin) + "\":$PATH\"\n"
    }

    /// The environment a tab's shell gets: the script's folder first on PATH (the zsh wrapper puts it first
    /// again after the user's startup files), and for Claude a per-tab env file that does the same, unless the
    /// user already set `CLAUDE_ENV_FILE`.
    static func environment(tab: UUID, inherited: [String: String]) -> [String: String] {
        var env = ["AGENTDE_BIN": binDirectory.path, "PATH": binDirectory.path + ":" + (inherited["PATH"] ?? "/usr/bin:/bin")]
        if inherited["CLAUDE_ENV_FILE"] == nil {
            try? FileManager.default.createDirectory(at: claudeEnvDirectory, withIntermediateDirectories: true)
            let file = claudeEnvDirectory.appendingPathComponent(tab.uuidString + ".sh")
            try? claudeEnvFile(bin: binDirectory.path).write(to: file, atomically: true, encoding: .utf8)
            env["CLAUDE_ENV_FILE"] = file.path
        }
        return env
    }

    /// Requests waiting in `folder`: the tab, the file or page, and the request's own file. Requests older than a
    /// day (another instance's tab, or one since closed) are deleted.
    static func pending(in folder: URL = requests, now: Date = Date()) -> [(tab: UUID, item: String, file: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { file in
            let name = file.lastPathComponent
            guard !name.hasPrefix("."), let tab = UUID(uuidString: String(name.prefix { $0 != "." })) else { return nil }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard now.timeIntervalSince(modified) < 86_400 else { try? FileManager.default.removeItem(at: file); return nil }
            guard let item = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !item.isEmpty else { return nil }
            return (tab, item, file)
        }
    }
}
