import Foundation

/// Where command-line tools the app runs are, found once.
public enum Tools {
    /// git from the Command Line Tools or Xcode (only once they're installed: `/usr/bin/git` is a stub that
    /// opens macOS's install dialog otherwise), else Homebrew's. Nil without one: Files and Changes then skip git.
    public static let git: String? = {
        var candidates: [String] = []
        if let developer = developerDirectory() { candidates.append(developer + "/usr/bin/git") }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The first executable `name` in the usual install folders (Homebrew, MacPorts, nix, mise, asdf, ~/.local/bin),
    /// then the app's PATH.
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = NSHomeDirectory()
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", home + "/.nix-profile/bin", "/run/current-system/sw/bin",
                       "/etc/profiles/per-user/\(NSUserName())/bin", home + "/.local/share/mise/shims", home + "/.asdf/shims",
                       home + "/.local/bin", "/usr/bin"]
        folders += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return folders.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The active developer folder (`xcode-select -p`), if it exists; asking never opens the install dialog.
    private static func developerDirectory() -> String? {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
