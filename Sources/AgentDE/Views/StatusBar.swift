import SwiftUI

/// The thin bar at the bottom: the active tab's kind and state, its session, waiting count, and usage limits.
struct StatusBar: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            if let tab = store.activeTab {
                let state = store.state(tab.id)
                Label(tab.kind.label, systemImage: tab.kind.symbol)
                switch state {
                case .working: Text("working").foregroundStyle(Theme.working)
                case .needsYou:
                    Text(store.runtime[tab.id]?.waitingFor.map { "needs you · " + Notifier.describeWaiting($0) } ?? "needs you")
                        .foregroundStyle(Theme.needsYou)
                case .doneUnseen: Text("done").foregroundStyle(Theme.doneUnseen)
                case .none: EmptyView()
                }
                if let id = tab.claudeSessionId {
                    Text(String(id.prefix(8)))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .help("Claude session \(id)")
                }
            }
            Spacer()
            if let version = store.updateInstalled {
                Button { AppRestart.restart() } label: {
                    Label("Update installed · Restart", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.doneUnseen)
                }
                .buttonStyle(.plain)
                .hint("\(AppBrand.name) \(version) is installed. Restarting keeps every tab running.")
            }
            let attention = store.runtime.values.filter { $0.state == .needsYou }.count
            if attention > 0 {
                Button { store.jumpToAttention() } label: {
                    Label("\(attention) waiting · ⌘J", systemImage: "bell")
                        .foregroundStyle(Theme.needsYou)
                }
                .buttonStyle(.plain)
            }
            if let five = store.rateLimits.fiveHour {
                Text("5h \(Int(five.rounded()))%")
                    .foregroundStyle(five > 85 ? Theme.needsYou : theme.muted)
            }
            if let seven = store.rateLimits.sevenDay {
                Text("7d \(Int(seven.rounded()))%")
                    .foregroundStyle(seven > 85 ? Theme.needsYou : theme.muted)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 0.5) }
    }
}
