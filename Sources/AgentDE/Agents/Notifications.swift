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

    enum Kind: Equatable { case needsYou, done }

    /// Records the event in the Notifications feed, then alerts as that kind's setting says: a banner, Termi
    /// popping up, both or neither.
    func notify(_ kind: Kind, tab: TabModel, title tabTitle: String, groupName: String, waitingFor: String?) {
        guard let settings = store?.settings else { return }
        let banner = kind == .needsYou ? settings.notifyNeedsYou : settings.notifyDone
        let termi = kind == .needsYou ? settings.termiNeedsYou : settings.termiDone
        let sound = settings.notificationSound
        queue.async { [weak self] in
            let title: String, body: String
            switch kind {
            case .needsYou:
                title = "Needs you · \(tabTitle)"
                body = waitingFor.map(Self.describeWaiting) ?? "Waiting for your input"
            case .done:
                title = "Done · \(tabTitle)"
                body = tab.agentSession.flatMap { session in Agents.of(tab)?.lastReply(session: session, cwd: tab.cwd) }
                    ?? "Turn finished"
            }
            if banner {
                let content = UNMutableNotificationContent()
                content.userInfo = ["tab": tab.id.uuidString]
                content.threadIdentifier = tab.id.uuidString
                content.subtitle = groupName
                content.title = title
                content.body = body
                if sound { content.sound = UNNotificationSound(named: UNNotificationSoundName(kind == .needsYou ? "Ping" : "Glass")) }
                // One banner per tab: a newer one replaces the previous.
                self?.center.add(UNNotificationRequest(identifier: tab.id.uuidString, content: content, trigger: nil))
            }
            DispatchQueue.main.async {
                guard let self, let store = self.store else { return }
                store.recordNotice(AgentNotice(tab: tab.id, kind: kind, title: title, group: groupName, body: body))
                if termi { self.popup.show(kind, tab: tab.id, animated: store.animations) }
            }
        }
    }

    /// Termi beside the banner (Settings → Fun). A click on him goes to the tab, like a click on the banner.
    private lazy var popup = TermiPopup { [weak self] id in self?.open(id) }

    private func open(_ id: UUID?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        if let id, store?.tab(id) != nil { store?.selectTab(id) }
    }

    func clear(tab: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [tab.uuidString])
        popup.hide(tab: tab)
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
            self?.open(id)
            completionHandler()
        }
    }
}

/// One entry in the Notifications feed: what the banner said (or would have, with banners off), and when.
struct AgentNotice: Identifiable, Equatable {
    let id = UUID()
    let tab: UUID
    let kind: Notifier.Kind
    let title: String
    let group: String
    let body: String
    var date = Date()
}

extension Store {
    /// The feed keeps this many, newest first, for this run of the app.
    static let noticeLimit = 100

    func recordNotice(_ notice: AgentNotice) { notices = Self.adding(notice, to: notices) }

    /// The feed with `notice` on top, trimmed to `noticeLimit`.
    static func adding(_ notice: AgentNotice, to feed: [AgentNotice]) -> [AgentNotice] {
        Array(([notice] + feed).prefix(noticeLimit))
    }

    func clearNotices() { notices.removeAll() }
}
