import AppKit

/// Restarting is safe at any time: tabs live in their holders, so only the window goes away and comes back.
enum AppRestart {
    /// Quits, and reopens the app (the installed copy, which may be a newer version) once this process is gone.
    static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        do {
            try task.run()
            DebugLog.log("restarting", "app")
            NSApp.terminate(nil)
        } catch {
            DebugLog.log("couldn't restart: \(error)", "app")
        }
    }

    /// Once a minute, compares the bundle on disk with the running build, and offers a restart when
    /// `make install` (or anything else) has put a different one there.
    static func watchForUpdates(store: Store) {
        let running = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            guard let info = NSDictionary(contentsOf: plist), let build = info["CFBundleVersion"] as? String,
                  build != running else { return }
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(build))"
            if store.updateInstalled != version {
                DebugLog.log("update installed: \(version)", "app")
                store.updateInstalled = version
            }
        }
    }
}
