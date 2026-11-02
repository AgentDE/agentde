import AppKit
import SwiftUI
import WebKit

/// A rendered Markdown file, styled to match the theme. Links open outside the preview; the file reloads
/// whenever it changes on disk (an agent editing the doc you're reading).
struct MarkdownView: NSViewRepresentable {
    let url: URL
    @Environment(\.theme) private var theme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let css = MarkdownView.css(theme)
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(css.hashValue)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        view.loadHTMLString(MarkdownView.page(for: url, theme: theme), baseURL: url.deletingLastPathComponent())
    }

    /// The file rendered as a themed HTML page.
    static func page(for url: URL, theme: Theme) -> String {
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css(theme))</style></head><body>"
            + MarkdownRenderer.html(source) + "</body></html>"
    }

    static func css(_ theme: Theme) -> String {
        func hex(_ color: Color) -> String {
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
            return String(format: "rgba(%d,%d,%d,%.2f)", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                          Int(c.blueComponent * 255), c.alphaComponent)
        }
        return """
        body { font: 14px/1.6 -apple-system, sans-serif; color: \(hex(theme.text)); background: transparent;
               max-width: 820px; margin: 0 auto; padding: 22px 28px 60px; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 .5em; } h1 { font-size: 1.7em; } h2 { font-size: 1.35em; }
        h1, h2 { border-bottom: 1px solid \(hex(theme.border)); padding-bottom: .25em; }
        p, ul, ol, table, pre, blockquote { margin: .7em 0; } li { margin: .2em 0; }
        a { color: #378ADD; } code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace;
        background: \(hex(theme.hover)); padding: .1em .35em; border-radius: 4px; }
        pre { background: \(hex(theme.hover)); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid \(hex(theme.border)); margin-left: 0; padding-left: 14px; color: \(hex(theme.secondary)); }
        table { border-collapse: collapse; } th, td { border: 1px solid \(hex(theme.border)); padding: 5px 10px; text-align: left; }
        th { background: \(hex(theme.hover)); } hr { border: none; border-top: 1px solid \(hex(theme.border)); }
        img { max-width: 100%; } del { color: \(hex(theme.muted)); }
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
