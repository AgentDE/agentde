import AppKit
import Darwin

/// Debug logging to `~/Library/Logs/<app name>/agentde.log` (rotated at 5 MB, one old copy kept), plus
/// two always-on diagnostics: a main-thread hang watchdog that saves a stack sample of any stall, and a
/// once-a-minute heartbeat with memory, CPU and per-tab terminal output rates (a stuck agent spewing output
/// shows up there).
public enum DebugLog {
    /// `AGENTDE_LOG_DIR` redirects logs (tests use it to keep out of the real log).
    public static let directory = ProcessInfo.processInfo.environment["AGENTDE_LOG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/" + AppBrand.name)
    public static let file = directory.appendingPathComponent("agentde.log")
    private static let queue = DispatchQueue(label: "agentde.log", qos: .utility)
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: @autoclosure () -> String, _ category: String = "app") {
        let line = "\(stamp.string(from: Date())) \(getpid()) [\(category)] \(message())\n"
        queue.async { write(line) }
    }

    private static func write(_ line: String) {
        if handle == nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
        }
        handle?.write(Data(line.utf8))
        if let size = try? handle?.offset(), size > 5_000_000 {
            try? handle?.close()
            handle = nil
            let old = directory.appendingPathComponent("agentde.1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
    }

    // MARK: Hang watchdog

    /// When the main thread last answered a ping, in seconds of uptime. Uptime stops while the Mac sleeps,
    /// so a night asleep doesn't read as a stall on wake.
    private static var lastPong = uptime()
    private static var lastSample = Date.distantPast
    private static var stallLogged = false

    public static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// Pings the main thread every half second from a background thread. A stall of 2 s or more is logged,
    /// and (at most every 5 minutes) `sample` captures where the main thread was stuck, into a hang-*.txt file.
    public static func startWatchdog() {
        let watchdog = DispatchQueue(label: "agentde.watchdog", qos: .userInitiated)
        func ping() {
            DispatchQueue.main.async { lastPongSet() }
            watchdog.asyncAfter(deadline: .now() + 0.5) {
                pongLock.lock()
                let stalled = uptime() - lastPong
                let newStall = stalled >= 2 && !stallLogged
                if newStall { stallLogged = true }
                pongLock.unlock()
                if newStall {
                    log(String(format: "main thread unresponsive for %.1fs", stalled), "hang")
                    if Date().timeIntervalSince(lastSample) > 300 {
                        lastSample = Date()
                        captureSample()
                    }
                }
                ping()
            }
        }
        ping()
    }

    private static let pongLock = NSLock()
    private static func lastPongSet() {
        pongLock.lock()
        if stallLogged {
            log(String(format: "main thread responsive again after %.1fs", uptime() - lastPong), "hang")
            stallLogged = false
        }
        lastPong = uptime()
        pongLock.unlock()
    }

    private static func captureSample() {
        let name = "hang-" + stamp.string(from: Date()).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-") + ".txt"
        let out = directory.appendingPathComponent(name)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        task.arguments = ["\(getpid())", "3", "-file", out.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            log("saved a 3 s stack sample of the stall to \(name)", "hang")
        } catch {
            log("couldn't run sample: \(error)", "hang")
        }
        // Keep the 10 newest samples.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let hangs = files.filter { $0.lastPathComponent.hasPrefix("hang-") }
                .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
            for old in hangs.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
        }
    }

    // MARK: Heartbeat

    /// Resident memory in MB and CPU time used so far (seconds), for the heartbeat.
    public static func processStats() -> (rssMB: Double, cpuSeconds: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return (result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0, cpu)
    }

    public static func openLog() {
        log("log opened")
        // Wait for queued writes so the file exists and is current before opening it.
        queue.async { DispatchQueue.main.async { NSWorkspace.shared.open(file) } }
    }

    public static func revealFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
