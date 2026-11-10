import SwiftUI
import WebKit

/// Keeps one web view per tab alive across tab switches so pages don't reload.
final class BrowserRegistry {
    private var views: [UUID: WKWebView] = [:]

    func webView(for id: UUID) -> WKWebView {
        if let view = views[id] { return view }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        views[id] = view
        return view
    }

    func remove(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
    }
}

struct BrowserPane: View {
    let tab: TabModel
    let store: Store
    @Environment(\.theme) private var theme
    @State private var address = ""
    @State private var model = BrowserModel()
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .hint("Back")
                Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .hint("Forward")
                Button { if model.loading { model.webView?.stopLoading() } else { model.webView?.reload() } } label: {
                    Image(systemName: model.loading ? "xmark" : "arrow.clockwise")
                }
                .hint(model.loading ? "Stop loading" : "Reload")
                TextField("localhost:5173 or a URL", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.border, lineWidth: 0.5))
                    .focused($addressFocused)
                    .onSubmit(load)
                Button { if let url = model.webView?.url { NSWorkspace.shared.open(url) } } label: {
                    Image(systemName: "safari")
                }
                .hint("Open in your browser")
                Button { store.toggleBrowser(tab.id) } label: { Image(systemName: "xmark") }
                    .hint("Hide browser")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondary)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.window)
            Divider().overlay(theme.border)
            WebViewHost(webView: store.terminals.browsers.webView(for: tab.id), model: model) { url in
                address = url
                store.setBrowserURL(tab.id, url)
            }
        }
        .onAppear {
            address = tab.browserURL ?? ""
            if model.webView?.url == nil, !address.isEmpty { load() }
            if address.isEmpty { addressFocused = true }
        }
    }

    private func load() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            text = "file://" + (text as NSString).expandingTildeInPath
        } else if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix(":")
                || text.allSatisfy(\.isNumber)
            if text.hasPrefix(":") { text = "localhost" + text }
            if text.allSatisfy(\.isNumber) { text = "localhost:" + text }
            text = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: text) else { return }
        if url.isFileURL {
            model.webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            model.webView?.load(URLRequest(url: url))
        }
    }
}

@Observable
final class BrowserModel {
    var canGoBack = false
    var canGoForward = false
    var loading = false
    @ObservationIgnored weak var webView: WKWebView?
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let model: BrowserModel
    let onNavigate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onNavigate: onNavigate) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(container, context: context)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        attach(container, context: context)
    }

    private func attach(_ container: NSView, context: Context) {
        model.webView = webView
        webView.navigationDelegate = context.coordinator
        // A reused container may still hold another tab's page, which would cover this one.
        for other in container.subviews where other !== webView { other.removeFromSuperview() }
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
        context.coordinator.sync(webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        var onNavigate: (String) -> Void

        init(model: BrowserModel, onNavigate: @escaping (String) -> Void) {
            self.model = model
            self.onNavigate = onNavigate
        }

        func sync(_ webView: WKWebView) {
            model.canGoBack = webView.canGoBack
            model.canGoForward = webView.canGoForward
            model.loading = webView.isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync(webView) }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            sync(webView)
            if let url = webView.url?.absoluteString { onNavigate(url) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { sync(webView) }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            sync(webView)
        }
    }
}
