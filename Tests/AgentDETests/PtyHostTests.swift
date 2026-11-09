import Darwin
import Foundation
import Testing
@testable import AgentDE

/// The terminal holder, driven through `PtyHost` and `PtyConnection` the way tabs use it.
@Suite("Terminal holder", .serialized)
struct PtyHostTests {
    /// The `agentde-pty` that `swift test` built alongside the tests: in the `.build` of this package, or of a
    /// workspace package further up that builds it.
    static let holder: URL? = {
        var roots: [URL] = []
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { roots.append(dir) }
            dir.deleteLastPathComponent()
        }
        let candidates = roots.flatMap { root in
            (FileManager.default.enumerator(at: root.appendingPathComponent(".build"), includingPropertiesForKeys: [.contentModificationDateKey])?
                .compactMap { $0 as? URL } ?? [])
                .filter { $0.lastPathComponent == "agentde-pty" && FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return candidates.max { a, b in
            let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
            return date(a) < date(b)
        }
    }()

    /// Short enough for a socket path (104 bytes), unlike the system temporary folder.
    let dir = NSHomeDirectory() + "/.config/agentde/pty-test-" + String(UUID().uuidString.prefix(8))

    func spawn(_ script: String, ring: Int = PtyHost.ringBytes, cwd: String = "/tmp") throws -> String {
        let holder = try #require(Self.holder)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let socket = dir + "/t.sock"
        let env = ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8", "HOME=" + NSHomeDirectory(), "AGENTDE_RUN=echo should-not-run"]
        #expect(PtyHost.spawn(holder: holder, socket: socket, rows: 24, cols: 80, ringBytes: ring, cwd: cwd,
                              executable: "/bin/sh", argv0: "sh", args: ["-c", script], environment: env))
        return socket
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: dir) }

    /// Collects a connection's events on the main thread until `until` holds or time runs out.
    final class Recorder {
        var output = ""
        var replay = ""
        var replayEnded = false
        var shell: pid_t = 0
        var exitStatus: Int32?
        var closed = false
        let connection: PtyConnection

        init(fd: Int32) {
            connection = PtyConnection(fd: fd)
            connection.onEvent = { [self] event in
                switch event {
                case .hello(_, _, let pid): shell = pid
                case .output(let bytes, let isReplay):
                    let text = String(decoding: bytes, as: UTF8.self)
                    if isReplay { replay += text } else { output += text }
                case .replayEnd: replayEnded = true
                case .exited(let status): exitStatus = status
                case .closed: closed = true
                }
            }
            connection.start()
        }

        /// Yields the main actor while waiting, so the connection's main-queue deliveries run.
        @MainActor func wait(_ seconds: Double = 5, until done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    @MainActor @Test func runsTheProgramTakesInputAndReportsItsExit() async throws {
        defer { cleanUp() }
        let socket = try spawn("echo ready; read line; echo \"got $line\"; exit 3")
        let fd = try #require(PtyHost.connect(path: socket))
        let tab = Recorder(fd: fd)
        await tab.wait { (tab.replay + tab.output).contains("ready") && tab.replayEnded }
        #expect(tab.shell > 0)
        tab.connection.send(input: Array("hello\r".utf8)[...])
        await tab.wait { tab.exitStatus != nil }
        #expect(tab.output.contains("got hello"))
        #expect(tab.exitStatus.map { ($0 >> 8) & 0xff } == 3)
        await tab.wait { tab.closed }
        #expect(!FileManager.default.fileExists(atPath: socket))   // the holder cleans up after itself
    }

    @MainActor @Test func aNewConnectionReplaysEarlierOutputFromTheSameShell() async throws {
        defer { cleanUp() }
        let socket = try spawn("echo first-line; sleep 30")
        let first = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await first.wait { (first.replay + first.output).contains("first-line") }
        let shell = first.shell
        first.connection.close()
        await first.wait { first.closed }

        let second = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await second.wait { second.replayEnded }
        #expect(second.replay.contains("first-line"))
        #expect(second.shell == shell)
        #expect(kill(shell, 0) == 0)                // still running between connections
        kill(shell, SIGKILL)
        await second.wait { second.exitStatus != nil }
        #expect(second.exitStatus != nil)
    }

    @MainActor @Test func replayRestoresTheModesTheProgramSwitchedOn() async throws {
        defer { cleanUp() }
        // Bracketed paste on, mouse reporting on then off again.
        let socket = try spawn("printf '\\033[?2004h\\033[?1000h\\033[?1000lmodes-set\\n'; sleep 30")
        let first = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await first.wait { (first.replay + first.output).contains("modes-set") }
        first.connection.close()
        let second = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await second.wait { second.replayEnded }
        let tail = second.replay.components(separatedBy: "modes-set").last ?? ""
        #expect(tail.contains("\u{1b}[?2004h"))
        #expect(tail.contains("\u{1b}[?1000l"))
        kill(second.shell, SIGKILL)
        await second.wait { second.exitStatus != nil }
    }

    @MainActor @Test func aWrappedReplayStartsAtALineBoundary() async throws {
        defer { cleanUp() }
        // 300 numbered lines through a 1 KB ring: the replay must begin with a whole line.
        let socket = try spawn("i=0; while [ $i -lt 300 ]; do echo \"line-$i-padding\"; i=$((i+1)); done; echo done-writing; sleep 30", ring: 1024)
        let first = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await first.wait { (first.replay + first.output).contains("done-writing") }
        first.connection.close()
        let second = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await second.wait { second.replayEnded }
        #expect(second.replay.hasPrefix("line-"))
        #expect(second.replay.contains("done-writing"))
        #expect(!second.replay.contains("line-0-"))
        kill(second.shell, SIGKILL)
        await second.wait { second.exitStatus != nil }
    }

    /// A 2 MB paste, more than the holder's 1 MB frame limit, arrives whole and the connection survives.
    @MainActor @Test func aPasteBiggerThanOneFrameArrivesWhole() async throws {
        defer { cleanUp() }
        // Counts 2.5 MB of input; stty raw so the line discipline doesn't cap a line.
        let socket = try spawn("stty raw -echo; echo ready; n=$(head -c 2621440 | wc -c); echo \"got $n\"; sleep 30")
        let tab = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await tab.wait { (tab.replay + tab.output).contains("ready") && tab.replayEnded }
        let size = 40 * 65536   // 2.5 MB
        tab.connection.send(input: [UInt8](repeating: UInt8(ascii: "x"), count: size)[...])
        await tab.wait(20) { tab.output.contains("got ") }
        #expect(tab.output.contains("\(size)"))
        #expect(!tab.closed)
        kill(tab.shell, SIGKILL)
        await tab.wait { tab.exitStatus != nil }
    }

    /// A folder the shell can't enter: no command, no startup run; a plain shell in ~ that says why.
    @MainActor @Test func aFolderThatCantBeEnteredRunsOnlyAPlainShell() async throws {
        defer { cleanUp() }
        let locked = dir + "-locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        chmod(locked, 0o600)
        defer { chmod(locked, 0o755); try? FileManager.default.removeItem(atPath: locked) }
        let socket = try spawn("echo the-command-ran; sleep 30", cwd: locked)
        let tab = Recorder(fd: try #require(PtyHost.connect(path: socket)))
        await tab.wait { (tab.replay + tab.output).contains("can't open folder") }
        let text = tab.replay + tab.output
        #expect(text.contains("can't open folder \(locked)"))
        #expect(!text.contains("the-command-ran"))
        kill(tab.shell, SIGKILL)
        await tab.wait { tab.exitStatus != nil }
    }

    @Test func socketFoldersDependOnlyOnTheStatePath() {
        #expect(PtyHost.stableHash("/a/state.json") == PtyHost.stableHash("/a/state.json"))
        #expect(PtyHost.stableHash("/a/state.json") != PtyHost.stableHash("/b/state.json"))
        #expect(PtyHost.stableHash("").count == 8)
        #expect(PtyHost.socketPath(for: UUID()).utf8.count < 104)
    }
}
