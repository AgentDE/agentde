import AppKit
import SwiftUI

/// The panel beside a terminal tab: the extensions' tabs (Workstream, say), then Files and Changes, with a
/// small switcher on top.
struct SidePanel: View {
    let tab: TabModel
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let tabs = store.sidePanelTabs(for: tab)
        let current = tabs.first { $0.id == tab.panelTab } ?? tabs.first
        VStack(spacing: 0) {
            // Plain text tabs with an underline, level with the tab strip beside it.
            HStack(spacing: 14) {
                ForEach(tabs) { item in
                    let selected = item.id == current?.id
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? theme.text : theme.muted)
                        .lineLimit(1)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if selected { Rectangle().fill(theme.text).frame(height: 1.5) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.setPanelTab(tab.id, item.id) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: store.settings.density == .compact ? 34 : 40)
            // A visible rule the underline sits on, so it doesn't just end in black.
            .overlay(alignment: .bottom) { Rectangle().fill(theme.muted.opacity(0.35)).frame(height: 0.5) }
            if let current { current.view.id(current.id).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        // No edge of its own: the resize handle beside it draws the divider.
        .background(theme.sidebar.opacity(0.55))
    }
}
