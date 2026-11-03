import Foundation

/// Runs a tab's startup command and agent inside a normal interactive login zsh.
///
/// Each tab's zsh gets `ZDOTDIR` pointed at small wrapper files. They source the user's own startup files
/// (so conda, PATH and prompt setup all load as usual), then run `AGENTDE_RUN` once, just before the first
/// prompt. The agent is a child of the interactive shell, so when it exits you're back at the same prompt
/// with the same environment (for example, the conda env still active).
enum ShellIntegration {
    static let directory = URL(fileURLWithPath: AppBrand.configDirectory).appendingPathComponent("zsh")

    /// Writes the wrapper files. Cheap and idempotent, so it runs at every launch to keep them current.
    static func install() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try? contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Whether a shell can use the wrapper; other shells fall back to `-c` with the command inlined.
    static func supports(shell: String) -> Bool {
        (shell as NSString).lastPathComponent == "zsh"
    }

    private static let header = "# Written by \(AppBrand.name) at launch; edits are overwritten. See ShellIntegration.swift.\n"

    /// Sources one of the user's startup files with ZDOTDIR temporarily pointing at the user's directory.
    private static func passthrough(_ file: String) -> String {
        """
        \(header)ZDOTDIR=$AGENTDE_USER_ZDOTDIR
        [[ -r $ZDOTDIR/\(file) ]] && source $ZDOTDIR/\(file)
        ZDOTDIR=$AGENTDE_ZDOTDIR

        """
    }

    private static let files: [String: String] = [
        ".zshenv": """
        \(header)AGENTDE_ZDOTDIR=$ZDOTDIR
        ZDOTDIR=${AGENTDE_USER_ZDOTDIR:-$HOME}
        [[ -r $ZDOTDIR/.zshenv ]] && source $ZDOTDIR/.zshenv
        AGENTDE_USER_ZDOTDIR=$ZDOTDIR
        ZDOTDIR=$AGENTDE_ZDOTDIR

        """,
        ".zprofile": passthrough(".zprofile"),
        ".zshrc": """
        \(header)ZDOTDIR=$AGENTDE_USER_ZDOTDIR
        # /etc/zshrc derives HISTFILE from ZDOTDIR before this runs; point history back at the user's file.
        [[ $HISTFILE == $AGENTDE_ZDOTDIR/* ]] && HISTFILE=$ZDOTDIR/.zsh_history
        [[ -r $ZDOTDIR/.zshrc ]] && source $ZDOTDIR/.zshrc
        # ZDOTDIR stays on the user's directory from here: zsh reads their .zlogin next, and child shells are untouched.
        unset AGENTDE_ZDOTDIR AGENTDE_USER_ZDOTDIR
        # `open <file>` shows it in the tab's viewer (OpenInViewer.swift): its script comes first on PATH.
        [[ -n ${AGENTDE_BIN-} ]] && path=($AGENTDE_BIN ${path:#$AGENTDE_BIN})

        if [[ -n ${AGENTDE_RUN-} ]]; then
          _agentde_run() {
            precmd_functions=(${precmd_functions:#_agentde_run})
            local run=$AGENTDE_RUN
            unset AGENTDE_RUN
            eval "$run"
          }
          precmd_functions+=(_agentde_run)
        fi

        """,
    ]
}
