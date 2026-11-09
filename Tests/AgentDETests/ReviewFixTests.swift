import Darwin
import Foundation
import Testing
@testable import AgentDE

/// Fixes from the November 2026 code reviews.
@Suite("Review fixes")
struct ReviewFixTests {
    @Test func clipboardReadsAreOffByDefaultAndNeverDuringAReplay() {
        #expect(AgentDESettings().allowClipboardRead == false)
        #expect(AgentDESettings.decodeLenient(from: Data("{}".utf8)).allowClipboardRead == false)
        #expect(TerminalSession.answersClipboardRead(allowed: false, replaying: false) == false)
        #expect(TerminalSession.answersClipboardRead(allowed: true, replaying: true) == false)
        #expect(TerminalSession.answersClipboardRead(allowed: true, replaying: false))
    }

    @Test func otherAppsOpenOnlyFromALinkClickInThePage() {
        #expect(ViewerHost.opensExternally(linkActivated: true, mainFrame: true))
        #expect(!ViewerHost.opensExternally(linkActivated: false, mainFrame: true))    // a script's navigation
        #expect(!ViewerHost.opensExternally(linkActivated: true, mainFrame: false))    // a link in an iframe
        #expect(ViewerHost.webSchemes.contains("https") && !ViewerHost.webSchemes.contains("shortcuts"))
    }

    @Test func aFolderMustBeEnterableNotJustPresent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-enter-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { chmod(dir, 0o755); try? FileManager.default.removeItem(atPath: dir) }
        #expect(TerminalSession.canEnter(folder: dir))
        chmod(dir, 0o600)                                    // exists, but no search permission
        #expect(!TerminalSession.canEnter(folder: dir))
        #expect(!TerminalSession.canEnter(folder: dir + "/missing"))
        let file = dir + ".file"
        FileManager.default.createFile(atPath: file, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: file) }
        #expect(!TerminalSession.canEnter(folder: file))     // a file isn't a folder
    }

    @Test func onlyOneProcessHoldsTheStateLock() {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-lock-\(UUID().uuidString)/state.json").path
        defer { try? FileManager.default.removeItem(atPath: (state as NSString).deletingLastPathComponent) }
        guard case .acquired(let fd) = InstanceLock.acquire(statePath: state) else {
            Issue.record("the first acquire should succeed")
            return
        }
        // flock locks belong to an open file description, so a second open in this process conflicts too.
        #expect(InstanceLock.acquire(statePath: state) == .held)
        close(fd)
        // Other tests fork processes in parallel, and a child holds a copy of every open descriptor (this lock's
        // too) for the instant between fork and exec, so the lock can stay held a moment after close. Allow 2 s.
        var again: Int32?
        let deadline = Date().addingTimeInterval(2)
        while again == nil, Date() < deadline {
            if case .acquired(let fd) = InstanceLock.acquire(statePath: state) { again = fd } else { usleep(20_000) }
        }
        guard let again else {
            Issue.record("the lock should be free once the holder closes it")
            return
        }
        close(again)
    }
}
