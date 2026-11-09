import Darwin
import Foundation

/// Finds, starts and connects to the `agentde-pty` holders that own tabs' terminals.
///
/// Each tab's shell runs under its own holder process, detached from AgentDE, which keeps the
/// pseudo-terminal, the last 2 MB of output and the terminal modes in effect. AgentDE talks to it over
/// a Unix socket, so quitting, updating or crashing the app leaves every shell and agent running, and the
/// next launch reconnects. Holders live in `~/.config/<data folder>/pty/<id>/`, where `<id>` hashes the state
/// file's path, so a test instance (`AGENTDE_STATE`) never sees your tabs.
enum PtyHost {
    static let ringBytes = 2 * 1024 * 1024

    static var stateFilePath: String {
        ProcessInfo.processInfo.environment["AGENTDE_STATE"]
            ?? AppBrand.configDirectory + "/state.json"
    }

    /// FNV-1a: stable across launches, unlike Swift's seeded `Hasher`.
    static func stableHash(_ text: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        return String(format: "%08x", hash)
    }

    static let directory: String = AppBrand.configDirectory + "/pty/" + stableHash(stateFilePath)

    static func socketPath(for tabID: UUID) -> String { directory + "/" + tabID.uuidString + ".sock" }

    /// The socket of the tab's running holder, if there is one.
    static func existingSocket(for tabID: UUID) -> String? {
        let path = socketPath(for: tabID)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Creates the socket folder, private to this user, and checks nobody swapped in a symlink or a
    /// folder owned by someone else.
    static func prepareDirectory() -> Bool {
        let parent = (directory as NSString).deletingLastPathComponent
        for path in [parent, directory] {
            if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
            if info.st_mode & 0o077 != 0 { chmod(path, 0o700) }
        }
        return true
    }

    /// Whether a holder for this tab appears to be running (its socket exists). `connect` is the real test.
    static func hasHolder(_ tabID: UUID) -> Bool {
        existingSocket(for: tabID) != nil
    }

    /// Tab ids of every holder socket in this instance's folders.
    static func holderIDs() -> [UUID] {
        [directory].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { name in
                name.hasSuffix(".sock") ? UUID(uuidString: String(name.dropLast(5))) : nil
            }
        }
    }

    /// Connects to a holder's socket, or nil if none is listening there.
    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    static var bundledHolder: URL? { Bundle.main.url(forAuxiliaryExecutable: "agentde-pty") }

    /// Starts a holder running `executable` (argv[0] `argv0`) in `cwd`, and waits until its socket accepts
    /// connections. Blocks for a few milliseconds; call it off the main thread.
    static func spawn(holder: URL, socket: String, rows: Int, cols: Int, ringBytes: Int = ringBytes, cwd: String,
                      executable: String, argv0: String, args: [String], environment: [String]) -> Bool {
        let argv = [holder.path, socket, String(rows), String(cols), String(ringBytes), cwd, executable, argv0] + args
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in cArgs { free(pointer) }
            for pointer in cEnv { free(pointer) }
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors below reach the holder: nothing of AgentDE's leaks into tabs.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        guard posix_spawn(&pid, holder.path, &actions, &attributes, &cArgs, &cEnv) == 0 else { return false }
        // The first process exits once the detached holder is listening (0) or has failed (non-zero).
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { break }
            if result < 0, errno == EINTR { continue }
            return FileManager.default.fileExists(atPath: socket)   // someone else reaped it
        }
        return (status & 0x7f) == 0 && (status >> 8) & 0xff == 0
    }
}

/// One connection to a holder. A reader thread parses its frames and hands them to the main thread in
/// order, a slice of time at a time, pausing reads while too much is waiting (so a flood of output slows
/// the program rather than growing memory). Writes go out on their own serial queue.
final class PtyConnection {
    enum Event {
        case hello(version: UInt32, holder: pid_t, shell: pid_t)
        case output([UInt8], replay: Bool)
        case replayEnd
        case exited(status: Int32)
        case closed
    }

    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "agentde.pty-write")
    /// Main thread only.
    var onEvent: ((Event) -> Void)?

    private let lock = NSCondition()
    private var pending: [Event] = []
    private var pendingBytes = 0
    private var drainScheduled = false
    private var shutDown = false
    private let highWater = 4 << 20, lowWater = 1 << 20

    init(fd: Int32) { self.fd = fd }

    deinit { Darwin.close(fd) }

    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "agentde.pty-read"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Sends input in frames of at most `inputChunk` bytes, in order: the holder drops a frame over 1 MB, which
    /// a big paste would otherwise be.
    func send(input bytes: ArraySlice<UInt8>) {
        var start = bytes.startIndex
        repeat {
            let end = bytes.index(start, offsetBy: Self.inputChunk, limitedBy: bytes.endIndex) ?? bytes.endIndex
            frame("i", Array(bytes[start..<end]))
            start = end
        } while start < bytes.endIndex
    }

    static let inputChunk = 64 * 1024

    func resize(rows: Int, cols: Int, xPixels: Int, yPixels: Int) {
        var payload: [UInt8] = []
        for value in [rows, cols, xPixels, yPixels] {
            let v = UInt16(clamping: value)
            payload += [UInt8(v >> 8), UInt8(v & 0xff)]
        }
        frame("w", payload)
    }

    /// Asks the program in front to redraw (SIGWINCH).
    func redraw() { frame("d", []) }

    /// Disconnects. The holder, and the tab's processes, keep running.
    func close() {
        lock.lock()
        shutDown = true
        lock.broadcast()
        lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    private func frame(_ type: Character, _ payload: [UInt8]) {
        let n = UInt32(payload.count)
        let bytes = [type.asciiValue!, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + payload
        writeQueue.async { [self] in
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    private func readLoop() {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        reading: while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            var offset = 0
            while buffer.count - offset >= 5 {
                let length = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16
                    | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
                guard buffer.count - offset - 5 >= length else { break }
                let payload = Array(buffer[(offset + 5)..<(offset + 5 + length)])
                switch buffer[offset] {
                case UInt8(ascii: "h") where length >= 12:
                    let u = { (i: Int) in UInt32(payload[i]) << 24 | UInt32(payload[i + 1]) << 16 | UInt32(payload[i + 2]) << 8 | UInt32(payload[i + 3]) }
                    enqueue(.hello(version: u(0), holder: pid_t(bitPattern: u(4)), shell: pid_t(bitPattern: u(8))), bytes: 0)
                case UInt8(ascii: "r"): enqueue(.output(payload, replay: true), bytes: length)
                case UInt8(ascii: "o"): enqueue(.output(payload, replay: false), bytes: length)
                case UInt8(ascii: "e"): enqueue(.replayEnd, bytes: 0)
                case UInt8(ascii: "x") where length >= 4:
                    let status = Int32(bitPattern: UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3]))
                    enqueue(.exited(status: status), bytes: 0)
                default: break
                }
                offset += 5 + length
                if isShutDown { break reading }
            }
            buffer.removeFirst(offset)
            // Backpressure: wait for the main thread to catch up before reading more.
            lock.lock()
            while pendingBytes > highWater, !shutDown { lock.wait() }
            let stop = shutDown
            lock.unlock()
            if stop { break }
        }
        enqueue(.closed, bytes: 0)
    }

    private var isShutDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shutDown
    }

    private func enqueue(_ event: Event, bytes: Int) {
        lock.lock()
        pending.append(event)
        pendingBytes += bytes
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { [self] in drain() } }
    }

    /// Delivers waiting events for up to 8 ms, then yields to the run loop so typing and drawing stay smooth.
    private func drain() {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                drainScheduled = false
                lock.unlock()
                return
            }
            let event = pending.removeFirst()
            if case .output(let bytes, _) = event { pendingBytes -= bytes.count }
            if pendingBytes <= lowWater { lock.broadcast() }
            lock.unlock()
            onEvent?(event)
            if DispatchTime.now().uptimeNanoseconds - start > 8_000_000 {
                DispatchQueue.main.async { [self] in drain() }
                return
            }
        }
    }
}
