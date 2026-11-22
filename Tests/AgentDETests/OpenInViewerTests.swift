import Foundation
import Testing
@testable import AgentDE

@Suite("open in the viewer", .serialized)
struct OpenInViewerTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-open-\(UUID().uuidString)")
    let tab = UUID()

    /// Runs the script in `root/work` with `arguments`; the real `open` is a stub that records what it got.
    /// `typed` runs it from a shell, as when you type it; otherwise its parent is this test, like a program's.
    func run(_ arguments: [String], inTab: Bool = true, typed: Bool = true) throws -> (requests: [(tab: UUID, item: String, file: URL)], fallback: String) {
        let work = root.appendingPathComponent("work"), requests = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("open.sh"), fallback = root.appendingPathComponent("fallback.txt")
        try OpenInViewer.script(requests: requests).write(to: script, atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("real-open")
        try "#!/bin/sh\necho \"$*\" > '\(fallback.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        try? FileManager.default.removeItem(at: fallback)
        try? FileManager.default.removeItem(at: requests)

        // Typed: sh under the name of a tab's holder, as in the app, where nothing above the holder counts.
        let holder = root.appendingPathComponent("agentde-pty")
        if !FileManager.default.fileExists(atPath: holder.path) {
            try FileManager.default.createSymbolicLink(atPath: holder.path, withDestinationPath: "/bin/sh")
        }
        let process = Process()
        process.executableURL = typed ? holder : URL(fileURLWithPath: "/bin/sh")
        // The trailing `:` keeps sh from exec'ing the script in its own place, so sh stays its parent.
        // holder → your shell → open, as when you type it in a tab.
        let typedRun = "/bin/sh -c " + TerminalSession.shellQuoted("/bin/sh \"$0\" \"$@\"; :") + " \"$0\" \"$@\"; :"
        process.arguments = typed ? ["-c", typedRun, script.path] + arguments : [script.path] + arguments
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "AGENTDE_REAL_OPEN": stub.path]
            .merging(inTab ? ["AGENTDE_TAB_ID": tab.uuidString] : [:]) { $1 }
        try process.run()
        process.waitUntilExit()
        return (OpenInViewer.pending(in: requests), (try? String(contentsOf: fallback, encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? "")
    }

    /// Folder names with an apostrophe, `$` or backticks (a home folder like `O'Brien`) still work in the
    /// generated shell text.
    @Test func oddFolderNamesAreQuoted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let odd = root.appendingPathComponent("it's $HOME `x`")
        let work = root.appendingPathComponent("work"), requests = odd.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "hi".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("open.sh")
        try OpenInViewer.script(requests: requests).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/sh \"$0\" \"$@\"; :", script.path, "a.txt"]
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "AGENTDE_TAB_ID": tab.uuidString, "AGENTDE_REAL_OPEN": "/usr/bin/true"]
        try process.run()
        process.waitUntilExit()
        #expect(OpenInViewer.pending(in: requests).map(\.tab) == [tab])

        let bin = odd.appendingPathComponent("bin").path
        let env = root.appendingPathComponent("env.sh")
        try OpenInViewer.claudeEnvFile(bin: bin).write(to: env, atomically: true, encoding: .utf8)
        let source = Process(), out = Pipe()
        source.executableURL = URL(fileURLWithPath: "/bin/sh")
        source.arguments = ["-c", ". \"$0\"; printf %s \"$PATH\"", env.path]
        source.environment = ["PATH": "/usr/bin:/bin"]
        source.standardOutput = out
        try source.run()
        source.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == bin + ":/usr/bin:/bin")
    }

    /// `open` run by an agent (a `claude` or `codex` process above the shell): files and local pages go to the
    /// viewer, other web pages to the browser (#14).
    @Test func anAgentsWebPagesGoToTheBrowser() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work"), requests = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "hi".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("open.sh")
        try OpenInViewer.script(requests: requests).write(to: script, atomically: true, encoding: .utf8)
        // Stand-ins named like a tab's holder and an agent (sh under those names), so the walk up from `open`
        // stops at the tab's holder, as in the app, rather than at whatever runs these tests.
        let holder = root.appendingPathComponent("agentde-pty"), claude = root.appendingPathComponent("claude")
        try? FileManager.default.createSymbolicLink(atPath: holder.path, withDestinationPath: "/bin/sh")
        try FileManager.default.createSymbolicLink(atPath: claude.path, withDestinationPath: "/bin/sh")
        func open(_ item: String, agent: Bool) throws -> [String] {
            try? FileManager.default.removeItem(at: requests)
            let shell = "/bin/sh -c '/bin/sh \"$0\" \"$1\"; :' \"$0\" \"$1\"; :"
            let process = Process()
            process.executableURL = holder
            process.arguments = ["-c", (agent ? "\"$2\" -c " + TerminalSession.shellQuoted(shell) + " \"$0\" \"$1\"" : shell) + "; :",
                                 script.path, item, claude.path]
            process.currentDirectoryURL = work
            process.environment = ["PATH": "/usr/bin:/bin", "AGENTDE_TAB_ID": tab.uuidString, "AGENTDE_REAL_OPEN": "/usr/bin/true"]
            try process.run()
            process.waitUntilExit()
            return OpenInViewer.pending(in: requests).map { ($0.item as NSString).lastPathComponent }
        }
        #expect(try open("https://example.com/page", agent: true).isEmpty)
        #expect(try open("http://localhost:3000/dash", agent: true) == ["dash"])
        // Look-alikes are other sites: a longer name, or localhost as user info.
        #expect(try open("http://localhost.example.com/x", agent: true).isEmpty)
        #expect(try open("http://localhost:1@example.com/x", agent: true).isEmpty)
        #expect(try open("a.txt", agent: true) == ["a.txt"])
        // Typed by you (no agent between the holder and the shell): the page goes to the viewer.
        #expect(try open("https://example.com/page", agent: false) == ["page"])
    }

    /// A bash tab gets the app's bin folder first on PATH again after path_helper moved it back.
    @Test func bashTabsPutTheShimFirstAgain() throws {
        let fix = try #require(TerminalSession.bashPathFix(shell: "/bin/bash", inherited: [:]))
        #expect(TerminalSession.bashPathFix(shell: "/bin/zsh", inherited: [:]) == nil)
        #expect(TerminalSession.bashPathFix(shell: "/bin/bash", inherited: ["PROMPT_COMMAND": "mine"]) == nil)
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "eval \"$PROMPT_COMMAND\"; printf %s \"$PATH|${PROMPT_COMMAND-unset}\""]
        process.environment = ["AGENTDE_BIN": "/x/bin", "PATH": "/usr/bin:/x/bin:/bin", "PROMPT_COMMAND": fix]
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "/x/bin:/usr/bin:/bin|unset")
    }

    @Test func aFileOrPageInATabGoesToItsViewer() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "<p>hi</p>".write(to: work.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)

        let relative = try run(["report.html"])
        #expect(relative.requests.map(\.tab) == [tab] && relative.fallback.isEmpty)
        #expect(relative.requests.first.map { ($0.item as NSString).lastPathComponent == "report.html" && $0.item.hasPrefix("/") } == true)

        let page = try run(["https://example.com/a"])
        #expect(page.requests.first?.item == "https://example.com/a")
    }

    @Test func aProgramsPageOrASignInGoesToTheBrowser() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let program = try run(["https://example.com/a"], typed: false)
        #expect(program.requests.isEmpty && program.fallback == "https://example.com/a")
        for link in ["https://x.cloud.databricks.com/oidc/v1/authorize?client_id=databricks-cli&code_challenge=abc",
                     "https://example.com/login?redirect_uri=http%3A%2F%2Flocalhost%3A8020", "https://example.com/oauth/start"] {
            let signIn = try run([link])
            #expect(signIn.requests.isEmpty && signIn.fallback == link, "\(link)")
        }
    }

    @Test func everythingElseGoesToTheRealOpen() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work/folder"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("work/a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["-a", "Safari"], ["folder"], ["missing.txt"], ["a.txt", "a.txt"], ["mailto:me@example.com"]] {
            let result = try run(arguments)
            #expect(result.requests.isEmpty, "\(arguments)")
            #expect(result.fallback == arguments.joined(separator: " "), "\(arguments)")
        }
        let outside = try run(["a.txt"], inTab: false)
        #expect(outside.requests.isEmpty && outside.fallback == "a.txt")
    }

    @Test func oldRequestsAreDropped() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let old = requests.appendingPathComponent("\(tab.uuidString).1")
        try "/tmp/x".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        try "/tmp/y".write(to: requests.appendingPathComponent(".\(tab.uuidString).2"), atomically: true, encoding: .utf8)   // still being written
        #expect(OpenInViewer.pending(in: requests).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
