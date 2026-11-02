import AppKit
import PDFKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What kind of content a viewer item is, which decides how it's shown.
enum ViewerKind: Equatable {
    case markdown, html, web, pdf, image, diff, text, other

    /// Whether the find bar can search it.
    var findable: Bool { ![.image, .other].contains(self) }

    static func of(_ item: String) -> ViewerKind {
        if item.hasPrefix("http://") || item.hasPrefix("https://") { return .web }
        let ext = (item as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown": return .markdown
        case "html", "htm", "svg": return .html
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "ico", "icns": return .image
        case "diff", "patch": return .diff
        default: break
        }
        let known: Set<String> = ["txt", "log", "csv", "tsv", "json", "jsonl", "yml", "yaml", "toml", "ini", "cfg", "conf",
                                  "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "m", "mm", "cpp", "hpp",
                                  "cc", "rs", "go", "rb", "java", "kt", "sh", "zsh", "bash", "sql", "css", "scss", "xml",
                                  "plist", "r", "lua", "env", "gitignore", "makefile", "dockerfile", "ipynb"]
        if known.contains(ext) { return .text }
        if ext.isEmpty || UTType(filenameExtension: ext)?.conforms(to: .text) == true { return .text }
        return .other
    }

    /// How the item is shown: a Markdown file in raw mode is shown as its text.
    static func shown(_ item: String, raw: Bool) -> ViewerKind {
        let kind = of(item)
        return raw && kind == .markdown ? .text : kind
    }
}

/// Owns each tab's viewer, so its web, PDF and text views live as long as the tab rather than a SwiftUI body.
/// Esc closes the viewer that has keyboard focus (in the chat, Esc stays Claude's).
final class ViewerRegistry {
    private var hosts: [UUID: ViewerHost] = [:]
    private var escapeMonitor: Any?
    var onEscape: ((UUID) -> Void)?

    func host(for id: UUID) -> ViewerHost {
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, let responder = event.window?.firstResponder as? NSView,
                      let host = self.hosts.values.first(where: { responder.isDescendant(of: $0) }) else { return event }
                self.onEscape?(host.tabID)
                return nil
            }
        }
        if let existing = hosts[id] { return existing }
        let host = ViewerHost(tabID: id)
        hosts[id] = host
        return host
    }

    func existing(_ id: UUID) -> ViewerHost? { hosts[id] }

    func remove(_ id: UUID) {
        hosts[id]?.removeFromSuperview()
        hosts[id] = nil
    }
}

/// Shows one item: Markdown, local HTML or a localhost page (WebKit), PDF (PDFKit), images, diffs and text,
/// or anything else through Quick Look. Files reload when they change on disk.
final class ViewerHost: NSView, WKNavigationDelegate, WKUIDelegate {
    let tabID: UUID
    private var shown: (item: String, theme: String, raw: Bool)?
    private var content: NSView?
    private var web: WKWebView?
    private var fileWatch: DispatchSourceFileSystemObject?
    private var theme: Theme?
    /// Markdown shown as its text (`TabModel.viewerRaw`).
    private var raw = false

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: String, theme: Theme, raw: Bool = false) {
        let themeKey = "\(theme.text)\(theme.terminalBackground)"
        guard shown?.item != item || shown?.theme != themeKey || shown?.raw != raw else { return }
        let sameItem = shown?.item == item
        shown = (item, themeKey, raw)
        self.theme = theme
        self.raw = raw
        render(item, keepScroll: sameItem)
        if !sameItem { watch(item) }
    }

    /// Whether keyboard focus is inside the viewer.
    var hasFocus: Bool { (window?.firstResponder as? NSView)?.isDescendant(of: self) ?? false }

    func focusContent() { if let content { window?.makeFirstResponder(content) } }

    /// Finds `term` in what's showing, case-insensitively, wrapping around: the next match after the current
    /// one (or the previous one), or, while typing (`incremental`), the first from the current match on.
    /// Reports whether there's a match.
    func find(_ term: String, backwards: Bool, incremental: Bool = false, done: @escaping (Bool) -> Void) {
        guard !term.isEmpty, let item = shown?.item else { return done(true) }
        let options: NSString.CompareOptions = backwards ? [.caseInsensitive, .backwards] : [.caseInsensitive]
        switch ViewerKind.shown(item, raw: raw) {
        case .markdown, .html, .web:
            guard let web else { return done(false) }
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.caseSensitive = false
            configuration.wraps = true
            web.find(term, configuration: configuration) { done($0.matchFound) }
        case .pdf:
            guard let pdf = content as? PDFView, let document = pdf.document,
                  let match = document.findString(term, fromSelection: pdf.currentSelection, withOptions: options)
                    ?? document.findString(term, fromSelection: nil, withOptions: options) else { return done(false) }
            pdf.setCurrentSelection(match, animate: true)
            pdf.go(to: match)
            done(true)
        case .diff, .text:
            guard let text = (content as? NSScrollView)?.documentView as? NSTextView else { return done(false) }
            let string = text.string as NSString
            let selected = text.selectedRange()
            let from = incremental ? selected.location : NSMaxRange(selected)
            let rest = backwards ? NSRange(location: 0, length: selected.location)
                                 : NSRange(location: from, length: string.length - from)
            var match = string.range(of: term, options: options, range: rest)
            if match.location == NSNotFound { match = string.range(of: term, options: options) }
            guard match.location != NSNotFound else { return done(false) }
            text.setSelectedRange(match)
            text.scrollRangeToVisible(match)
            text.showFindIndicator(for: match)
            done(true)
        case .image, .other:
            done(false)
        }
    }

    /// Loads the item again, bypassing the cache: a page from its server (what's showing now, if you browsed
    /// on), a file from disk.
    func reload() {
        guard let item = shown?.item else { return }
        if let web, [.web, .html].contains(ViewerKind.of(item)) { web.reloadFromOrigin() } else { render(item, keepScroll: true) }
    }

    private func render(_ item: String, keepScroll: Bool = false) {
        guard let theme else { return }
        let url = item.hasPrefix("http") ? URL(string: ViewerLinks.openURL(item)) : URL(fileURLWithPath: item)
        guard let url else { return }
        switch ViewerKind.shown(item, raw: raw) {
        case .markdown:
            webView().loadHTMLString(MarkdownView.page(for: url, theme: theme), baseURL: url.deletingLastPathComponent())
        case .html:
            webView().loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case .web:
            webView().load(URLRequest(url: url))
        case .pdf:
            let pdf = (content as? PDFView) ?? PDFView()
            pdf.autoScales = true
            pdf.backgroundColor = theme.terminalBackground
            pdf.document = PDFDocument(url: url)
            install(pdf)
        case .image:
            let view = (content as? NSImageView) ?? NSImageView()
            view.imageScaling = .scaleProportionallyDown
            view.imageAlignment = .alignCenter
            view.image = NSImage(contentsOf: url)
            install(view)
        case .diff, .text:
            let scroll = (content as? NSScrollView) ?? NSTextView.scrollableTextView()
            guard let text = scroll.documentView as? NSTextView else { return }
            let offset = scroll.contentView.bounds.origin
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = true
            text.backgroundColor = theme.terminalBackground
            text.textContainerInset = NSSize(width: 14, height: 12)
            let contents = Self.readText(url)
            text.textStorage?.setAttributedString(ViewerHost.styled(contents, diff: ViewerKind.of(item) == .diff, theme: theme))
            scroll.drawsBackground = true
            scroll.backgroundColor = theme.terminalBackground
            install(scroll)
            if keepScroll { scroll.contentView.scroll(to: offset) }
        case .other:
            let preview = (content as? QLPreviewView) ?? QLPreviewView(frame: .zero, style: .normal)!
            preview.autostarts = true
            preview.previewItem = url as NSURL
            install(preview)
        }
    }

    /// At most 2 MB of a text file, so a huge log can't stall the window.
    static func readText(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 2_000_000)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func styled(_ text: String, diff: Bool, theme: Theme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.terminalForeground]
        guard diff else { return NSAttributedString(string: text, attributes: base) }
        let result = NSMutableAttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var attributes = base
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                attributes[.foregroundColor] = NSColor(srgbRed: 0.45, green: 0.85, blue: 0.6, alpha: 1)
                attributes[.backgroundColor] = NSColor(srgbRed: 0.24, green: 0.95, blue: 0.65, alpha: 0.08)
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                attributes[.foregroundColor] = NSColor(srgbRed: 1, green: 0.55, blue: 0.62, alpha: 1)
                attributes[.backgroundColor] = NSColor(srgbRed: 1, green: 0.37, blue: 0.54, alpha: 0.08)
            } else if line.hasPrefix("@@") {
                attributes[.foregroundColor] = NSColor(srgbRed: 0.49, green: 0.78, blue: 1, alpha: 1)
            } else if line.hasPrefix("diff ") || line.hasPrefix("+++") || line.hasPrefix("---") {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            }
            result.append(NSAttributedString(string: String(line) + "\n", attributes: attributes))
        }
        return result
    }

    /// Shared by every viewer and sign-in window, with the default persistent data store, so a login (to
    /// claude.ai, say) is remembered across tabs and launches.
    static let webConfiguration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }()

    /// Safari's, so sign-in pages (Google's among them) treat the viewer like a browser.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Windows a page opened (sign-in pop-ups), kept until they close.
    private var popups: [NSWindow] = []

    private func webView() -> WKWebView {
        if let web {
            install(web)
            return web
        }
        let view = WKWebView(frame: .zero, configuration: Self.webConfiguration)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        web = view
        install(view)
        return view
    }

    private func install(_ view: NSView) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        content = view
    }

    /// Reloads when the file changes; follows it across an atomic save (written elsewhere, renamed over it).
    private func watch(_ item: String) {
        fileWatch?.cancel()
        fileWatch = nil
        guard !item.hasPrefix("http") else { return }
        let fd = open(item, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let replaced = !source.data.intersection([.delete, .rename]).isEmpty
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.shown?.item == item else { return }
                self.render(item, keepScroll: true)
                if replaced { self.watch(item) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatch = source
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        // mailto:, app links and the like go to their apps.
        if let scheme = url.scheme?.lowercased(), !["http", "https", "file", "about", "data", "blob"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        guard webView === web, action.navigationType == .linkActivated else { return decisionHandler(.allow) }
        // A web page browses like a browser (sign-in flows cross sites); links out of a local page open in the browser.
        if let item = shown?.item, ViewerKind.of(item) == .web {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // MARK: WKUIDelegate

    /// A page opening a window (a "Sign in with…" pop-up): it gets a real window sharing the viewer's
    /// cookies, closed when the page closes it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let size = NSSize(width: windowFeatures.width?.doubleValue ?? 520, height: windowFeatures.height?.doubleValue ?? 680)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let popup = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        window.contentView = popup
        window.title = action.request.url?.host ?? "Sign in"
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.popups.removeAll { $0 === window }
        }
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = popups.first(where: { $0.contentView === webView }) else { return }
        window.close()
        popups.removeAll { $0 === window }
    }
}

/// Puts a tab's viewer host into SwiftUI without recreating it.
struct ViewerPane: NSViewRepresentable {
    let tabID: UUID
    let item: String
    let store: Store
    @Environment(\.theme) private var theme

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { attach(container) }

    /// SwiftUI reuses one container across tabs, so it can still hold another tab's viewer (which would cover
    /// this one): only this tab's stays.
    private func attach(_ container: NSView) {
        let host = store.terminals.viewers.host(for: tabID)
        for other in container.subviews where other !== host { other.removeFromSuperview() }
        if host.superview !== container {
            host.removeFromSuperview()
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
        }
        host.show(item, theme: theme, raw: store.tab(tabID)?.viewerRaw == true)
    }
}
