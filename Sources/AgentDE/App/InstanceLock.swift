import Darwin
import Foundation

/// One running copy per state file: two copies on the same state would take each other's terminal holders
/// in turn, forever, and overwrite each other's saved state.
enum InstanceLock {
    enum Result: Equatable {
        /// This process holds the lock; keep the descriptor open for its lifetime.
        case acquired(Int32)
        /// Another process holds it.
        case held
        /// The lock file couldn't be opened; carry on without it.
        case unavailable
    }

    static func lockPath(forState statePath: String) -> String { statePath + ".lock" }

    static func acquire(statePath: String) -> Result {
        let path = lockPath(forState: statePath)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .held
        }
        return .acquired(fd)
    }
}
