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
            HStack(spacing: 2) {
                ForEach(tabs) { item in
                    let selected = item.id == current?.id
                    Button { store.setPanelTab(tab.id, item.id) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 10.5))
                            Text(item.title).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.text.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? theme.text : theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            Divider().overlay(theme.border)
            if let current { current.view.id(current.id).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(theme.sidebar.opacity(0.55))
        .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 0.5) }
    }
}
