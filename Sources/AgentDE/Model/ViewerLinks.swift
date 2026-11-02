import Foundation

/// Links that open in a tab's viewer rather than the browser: Claude artifacts, plus extensions' link rules
/// (set at launch).
enum ViewerLinks {
    static let claude = LinkRule(pattern: #"https://claude\.ai/(?:code/)?artifacts?/[A-Za-z0-9_-]{8,}"#, marker: "claude.ai/",
                                 title: { _ in "Claude artifact" })
    static var rules: [LinkRule] = [claude]

    private static func matches(_ rule: LinkRule, _ link: String) -> Bool {
        link.contains(rule.marker) && link.range(of: rule.pattern, options: .regularExpression) != nil
    }

    /// The link's one form for its page, if a rule claims it.
    static func canonical(_ link: String) -> String? {
        var link = link
        while let last = link.last, ".,;:!?*_'\"".contains(last) { link.removeLast() }
        return rules.first { matches($0, link) }?.canonical(link)
    }

    static func isViewerLink(_ link: String) -> Bool { rules.contains { matches($0, link) } }

    /// The address to load for it.
    static func openURL(_ link: String) -> String { rules.first { matches($0, link) }?.openURL(link) ?? link }

    /// A title from the link itself, else its last path part.
    static func title(for link: String) -> String {
        rules.first { matches($0, link) }?.title(link) ?? (URL(string: link)?.lastPathComponent ?? link)
    }
}
