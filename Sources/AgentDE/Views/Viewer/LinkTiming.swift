import Foundation

/// Times a link from the click to the item on screen, for the `[link]` log: a ⌘-click in the terminal ("click")
/// or a link clicked in a page in the viewer ("page-click"). Main thread only; nothing runs without a pending click.
enum LinkTiming {
    private static var started: [UUID: (at: Date, from: String)] = [:]

    static func start(_ tab: UUID, from: String = "click") { started[tab] = (Date(), from) }

    /// Milliseconds since the pending click on `tab`, or nil when none is pending.
    static func elapsed(_ tab: UUID) -> Int? { started[tab].map { Int(Date().timeIntervalSince($0.at) * 1000) } }

    static var hasPending: Bool { !started.isEmpty }

    /// Logs the item as shown and ends the timing; does nothing without a pending click.
    static func shown(_ tab: UUID, item: String, kind: String) {
        guard let pending = started.removeValue(forKey: tab) else { return }
        let ms = Int(Date().timeIntervalSince(pending.at) * 1000)
        DebugLog.log("\(pending.from) → shown \((item as NSString).lastPathComponent) \(kind) in \(ms) ms", "link")
    }

    static func cancel(_ tab: UUID) { started[tab] = nil }
}
