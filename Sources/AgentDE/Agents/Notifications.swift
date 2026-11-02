import AppKit
import UserNotifications

/// macOS banners for agents that need you or have finished, while you're looking at something else.
/// Clicking a banner brings AgentDE forward on that tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var store: Store?
    private let center = UNUserNotificationCenter.current()
    private let queue = DispatchQueue(label: "agentde.notifier", qos: .utility)

    init(store: Store) {
        self.store = store
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    enum Kind { case needsYou, done }

    func notify(_ kind: Kind, tab: TabModel, title tabTitle: String, groupName: String, waitingFor: String?) {
        guard let settings = store?.settings else { return }
        switch kind {
        case .needsYou: guard settings.notifyNeedsYou else { return }
        case .done: guard settings.notifyDone else { return }
        }
        let sound = settings.notificationSound
        queue.async { [weak self] in
            let content = UNMutableNotificationContent()
            content.userInfo = ["tab": tab.id.uuidString]
            content.threadIdentifier = tab.id.uuidString
            content.subtitle = groupName
            switch kind {
            case .needsYou:
                content.title = "Needs you · \(tabTitle)"
                content.body = waitingFor.map(Self.describeWaiting) ?? "Waiting for your input"
                if sound { content.sound = UNNotificationSound(named: UNNotificationSoundName("Ping")) }
            case .done:
                content.title = "Done · \(tabTitle)"
                content.body = tab.claudeSessionId.flatMap { TranscriptPeek.lastAssistantText(sessionId: $0, cwd: tab.cwd) }
                    ?? "Turn finished"
                if sound { content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass")) }
            }
            // One banner per tab: a newer one replaces the previous.
            let request = UNNotificationRequest(identifier: tab.id.uuidString, content: content, trigger: nil)
            self?.center.add(request)
        }
    }

    func clear(tab: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [tab.uuidString])
    }

    /// Turns registry `waitingFor` values like `permission_prompt` into a readable phrase.
    static func describeWaiting(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "Waiting for your input" }
        return first.uppercased() + text.dropFirst()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["tab"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let id, self?.store?.tab(id) != nil { self?.store?.selectTab(id) }
            completionHandler()
        }
    }
}

/// Reads the end of a Claude transcript for the last thing the assistant said.
enum TranscriptPeek {
    /// `~/.claude/projects/<cwd with every non-alphanumeric character as "-">/<session>.jsonl`
    static func transcriptURL(sessionId: String, cwd: String) -> URL {
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects").appendingPathComponent(encoded)
            .appendingPathComponent(sessionId + ".jsonl")
    }

    static func lastAssistantText(sessionId: String, cwd: String, limit: Int = 180) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL(sessionId: sessionId, cwd: cwd)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let tail = try? handle.readToEnd() else { return nil }
        let marker = Data("\"type\":\"assistant\"".utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["isSidechain"] as? Bool != true,
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text.count > limit ? String(text.prefix(limit)) + "…" : text }
        }
        return nil
    }
}
