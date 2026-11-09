import AppKit

/// Restarting is safe at any time: tabs live in their holders, so only the window goes away and comes back.
enum AppRestart {
    /// Quits, and reopens the app (the installed copy, which may be a newer version) once this process is gone.
    /// Right after `make install`, LaunchServices can still be registering the new copy, and `open` then quietly
    /// launches nothing ("launch 0 items"). So the helper checks that the app came back, asks again a few times,
    /// and as a last resort starts its executable directly.
    static func restart() {
        guard let executable = Bundle.main.executablePath else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", Self.relaunchScript, Bundle.main.bundlePath, executable, String(getpid()), DebugLog.file.path, "5"]
        do {
            try task.run()
            DebugLog.log("restarting", "app")
            NSApp.terminate(nil)
        } catch {
            DebugLog.log("couldn't restart: \(error)", "app")
        }
    }

    /// `$0` the bundle, `$1` its executable, `$2` the pid to wait for, `$3` the log, `$4` how many times to `open`.
    /// "Running" means a process whose command line starts with the executable (not this helper, which only
    /// mentions it).
    static let relaunchScript = #"""
        bundle=$0 exe=$1 pid=$2 log=$3 tries=$4
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        running() { pgrep -f -- "^$exe" >/dev/null 2>&1; }
        attempt=0
        while [ "$attempt" -lt "$tries" ]; do
          attempt=$((attempt + 1))
          /usr/bin/open "$bundle" 2>/dev/null
          for _ in 1 2 3 4 5 6 7 8 9 10; do running && exit 0; sleep 0.3; done
          printf '%s [app] restart: open launched nothing (attempt %s)\n' "$(date '+%Y-%m-%d %H:%M:%S.000')" "$attempt" >> "$log"
        done
        running || nohup "$exe" >/dev/null 2>&1 &
        """#

    /// Once a minute, compares the bundle on disk with the running build, and offers a restart when
    /// `make install` (or anything else) has put a different one there: another build number, or the same
    /// number rebuilt (an install of uncommitted changes), which only the executable's date tells apart.
    static func watchForUpdates(store: Store) {
        let running = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        let executable = Bundle.main.executableURL
        let modified = { executable.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } }
        let launchedFrom = modified()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            guard let info = NSDictionary(contentsOf: plist), let build = info["CFBundleVersion"] as? String,
                  build != running || modified() != launchedFrom else { return }
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(build))"
            if store.updateInstalled != version {
                DebugLog.log("update installed: \(version)", "app")
                store.updateInstalled = version
            }
        }
    }
}
