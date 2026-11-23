import AppKit
import AgentDEKit
import SwiftUI

/// ⌃Tab: the agents with a status (working, needs you, done unseen, or a question waiting), across every group,
/// most recently used first. Hold ⌃ and tap Tab to move down the list (⌃⇧Tab up), let go to switch; Esc cancels.
struct TabSwitcherState: Equatable {
    var ids: [UUID]
    var index: Int

    /// The list: the tab you're on, then every other tab with a status, the one you used last first.
    static func order(current: UUID?, tabs: [(id: UUID, colored: Bool, usedAt: Date?)]) -> [UUID] {
        let others = tabs.filter { $0.colored && $0.id != current }
            .sorted { ($0.usedAt ?? .distantPast) > ($1.usedAt ?? .distantPast) }
            .map(\.id)
        return (current.map { [$0] } ?? []) + others
    }

    /// One step down (or up), wrapping.
    func stepped(_ delta: Int) -> TabSwitcherState {
        var next = self
        next.index = ((index + delta) % ids.count + ids.count) % ids.count
        return next
    }
}

extension Store {
    /// ⌃Tab pressed (⌃⇧Tab: `backwards`): opens the switcher on the next tab, or moves along it.
    func tabSwitcherStep(backwards: Bool) {
        if let open = tabSwitcher {
            tabSwitcher = open.stepped(backwards ? -1 : 1)
            return
        }
        let all = groups.flatMap(\.tabs).filter { $0.kind != .command }
        let ids = TabSwitcherState.order(current: activeTab?.id, tabs: all.map {
            (id: $0.id, colored: state($0.id) != .none || wantsAttention($0), usedAt: lastFocusedAt[$0.id] ?? $0.lastActiveAt)
        })
        guard ids.count > 1 else { NSSound.beep(); return }
        tabSwitcher = TabSwitcherState(ids: ids, index: backwards ? ids.count - 1 : 1)
    }

    /// ⌃ let go: switches to the highlighted tab.
    func tabSwitcherCommit() {
        guard let open = tabSwitcher else { return }
        tabSwitcher = nil
        if open.ids.indices.contains(open.index) { selectTab(open.ids[open.index]) }
    }

    func tabSwitcherCancel() { tabSwitcher = nil }
}

/// The keys: ⌃Tab and ⌃⇧Tab step, letting go of ⌃ switches, Esc cancels. Installed once, at launch.
@MainActor
enum TabSwitcherKeys {
    private static var monitors: [Any] = []

    static func install(_ store: Store) {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 48, flags.contains(.control), !flags.contains(.command), !flags.contains(.option) {   // Tab
                store.tabSwitcherStep(backwards: flags.contains(.shift))
                return nil
            }
            if event.keyCode == 53, store.tabSwitcher != nil {   // Esc
                store.tabSwitcherCancel()
                return nil
            }
            return event
        }) { monitors.append(keys) }
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            if store.tabSwitcher != nil, !event.modifierFlags.contains(.control) { store.tabSwitcherCommit() }
            return event
        }) { monitors.append(flags) }
    }
}

/// The list shown while ⌃ is held: icon, name and group of each tab, the highlighted one where you'll land.
struct TabSwitcherView: View {
    let state: TabSwitcherState
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(state.ids.enumerated()), id: \.element) { index, id in
                if let tab = store.tab(id) {
                    let group = store.groups.first { $0.tabs.contains { $0.id == id } }
                    HStack(spacing: 8) {
                        StatusIcon(name: store.icon(for: tab), state: store.state(id), idle: NSColor(theme.muted), animated: false, size: 13)
                            .frame(width: 16)
                        Text(store.title(for: tab)).font(.system(size: 13, weight: index == state.index ? .semibold : .regular))
                            .foregroundStyle(theme.text).lineLimit(1)
                        Spacer(minLength: 12)
                        if let group { Text(group.name).font(.system(size: 11.5)).foregroundStyle(theme.muted).lineLimit(1) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(index == state.index ? theme.selected : .clear))
                    .activeOutline(index == state.index, radius: 6)
                }
            }
        }
        .padding(8)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.window))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }
}
