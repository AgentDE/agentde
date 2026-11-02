import AppKit
import QuartzCore
import SwiftUI

/// A tiny burst of sparks, played once whenever `token` changes.
struct SparkleBurst: View {
    let token: Int
    let firedAt: Date?
    let color: Color
    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { i in
                let angle = Double(i) / 9 * 2 * .pi + 0.3
                Image(systemName: i % 3 == 0 ? "sparkle" : "circle.fill")
                    .font(.system(size: i % 3 == 0 ? 9 : 3.5, weight: .bold))
                    .foregroundStyle(i % 2 == 0 ? color : Theme.needsYou)
                    .offset(x: fired ? cos(angle) * 22 : 0, y: fired ? sin(angle) * 14 : 0)
                    .scaleEffect(fired ? 1 : 0.2)
                    .opacity(fired ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .id(token)
        .onAppear {
            guard token > 0, let firedAt, Date().timeIntervalSince(firedAt) < 2 else { return }
            withAnimation(.easeOut(duration: 0.9)) { fired = true }
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Inline rename field that commits on return or when focus leaves.
struct RenameField: View {
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { commit(text) }
            .onExitCommand { commit(initial) }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit(text) } }
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
    }
}

/// The app icon (whichever one Settings has chosen), read from the app so it always matches the Dock.
/// Optionally gives a little wiggle on hover.
struct AppLogo: View {
    var size: CGFloat
    var wiggleOnHover = false
    @Environment(Store.self) private var store
    @State private var wiggle = false

    var body: some View {
        // A theme can bring its own mascot in place of the icon.
        Image(nsImage: Theme.definition(store.settings.theme).logo?(size) ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(wiggle ? -6 : 0))
            .scaleEffect(wiggle ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.35), value: wiggle)
            .onHover { inside in if wiggleOnHover { wiggle = inside } }
            .hint(AppBrand.name)
            .accessibilityLabel(AppBrand.name)
    }
}
