import SwiftUI

/// The window: sidebar, then the main column (header, tab strip, work area, status bar), with the ⌘K and
/// search overlays on top. Resolves the theme for everything below it.
struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(\.colorScheme) private var systemScheme

    private var dark: Bool {
        switch store.settings.appearance {
        case .dark: true
        case .light: Theme.definition(store.settings.theme).alwaysDark
        case .system: Theme.definition(store.settings.theme).alwaysDark || systemScheme == .dark
        }
    }

    var body: some View {
        let theme = Theme.resolve(store.settings.theme, dark: dark)
        HStack(spacing: 0) {
            if store.sidebarVisible {
                Sidebar()
                    .frame(width: store.settings.sidebarWidth)
                    .background {
                        if store.settings.translucentSidebar, theme.outline == nil {
                            ZStack { VisualEffect(); theme.sidebar.opacity(0.55) }
                        } else {
                            theme.sidebar
                        }
                    }
                    .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 0.5) }
                    .transition(.move(edge: .leading))
            }
            MainColumn()
                .background(theme.window)
        }
        .overlay {
            if store.paletteOpen {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else if store.searchOpen {
                SessionSearchPanel()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.22), value: store.sidebarVisible)
        .animation(.snappy(duration: 0.15), value: store.paletteOpen)
        .animation(.snappy(duration: 0.15), value: store.searchOpen)
        .environment(\.theme, theme)
        .preferredColorScheme(store.settings.appearance == .system
                              ? (Theme.definition(store.settings.theme).alwaysDark ? .dark : nil)
                              : (dark ? .dark : .light))
        .ignoresSafeArea()
        .onChange(of: dark) { _, _ in store.terminals.applyAppearance() }
    }
}

private struct MainColumn: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            if store.settings.tabsPosition == .top { TabStrip() }
            WorkArea()
            if store.settings.tabsPosition == .bottom { TabStrip() }
            StatusBar()
        }
        .overlay(alignment: .top) {
            ForEach(Array(store.extensions.compactMap { $0.windowOverlay() }.enumerated()), id: \.offset) { _, overlay in
                overlay.allowsHitTesting(false)
                    .frame(height: 82)
                    .allowsHitTesting(false)
            }
        }
    }
}
