import AppKit
import AgentDEKit

/// A link's line: `model_selectors.py:33`, `a.swift:12:5` (the column is ignored), with sentence punctuation after it.
enum FileLink {
    static func line(_ link: String) -> Int? {
        let trimmed = Store.trimmedLink(link)
        guard let match = trimmed.range(of: #":([0-9]+)(:[0-9]+)?$"#, options: .regularExpression) else { return nil }
        let digits = trimmed[match].dropFirst().prefix { $0.isNumber }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The link without its `:line` or `:line:col`.
    static func withoutLine(_ link: String) -> String {
        link.replacingOccurrences(of: #":[0-9]+(:[0-9]+)?$"#, with: "", options: .regularExpression)
    }
}

/// Where each line of a text starts (UTF-16 offsets), for line numbers and going to a line.
enum LineIndex {
    static func starts(_ text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        var index = 0
        while index < length {
            let range = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: length - index))
            guard range.location != NSNotFound else { break }
            index = range.location + 1
            if index < length { starts.append(index) }
        }
        return starts
    }

    /// The 1-based line holding `offset`.
    static func line(at offset: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// Line `line` (1-based) without its newline; past the end, the last line.
    static func range(ofLine line: Int, in text: NSString) -> NSRange {
        let starts = starts(text)
        let index = min(max(line, 1), starts.count) - 1
        let start = starts[index]
        var end = index + 1 < starts.count ? starts[index + 1] - 1 : text.length
        if end > start, text.character(at: end - 1) == 10 { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }
}

/// Cheap coloring for code: comments, strings, numbers and keywords, from one scan with a few rules per family of
/// languages. No grammar, so it can be wrong at the edges (a regex literal, a heredoc); it never changes the text.
enum CodeColors {
    enum Kind { case comment, string, number, keyword }

    struct Language: Equatable {
        var line: [String]
        var block: (open: String, close: String)?
        var keywords: Set<String>
        var caseInsensitive = false
        var tripleQuotes = false

        static func == (a: Language, b: Language) -> Bool {
            a.line == b.line && a.block?.open == b.block?.open && a.keywords == b.keywords
        }
    }

    static let cFamily = Language(line: ["//"], block: ("/*", "*/"), keywords: [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "case",
        "switch", "break", "continue", "default", "guard", "in", "do", "try", "catch", "throw", "throws", "new", "this",
        "self", "super", "static", "public", "private", "protected", "internal", "final", "const", "function", "async",
        "await", "export", "from", "interface", "type", "extends", "implements", "package", "fn", "pub", "mut", "impl",
        "match", "use", "mod", "trait", "where", "nil", "null", "true", "false", "undefined", "void", "extension",
        "protocol", "init", "deinit", "typealias", "override", "go", "defer", "chan", "select", "range", "val", "fun",
        "object", "when", "is", "as", "of", "delete", "typeof", "instanceof", "yield", "loop", "ref", "inout", "some", "any"])
    static let hashFamily = Language(line: ["#"], block: nil, keywords: [
        "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "with", "try",
        "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "async", "await", "not", "and",
        "or", "is", "None", "True", "False", "self", "global", "nonlocal", "assert", "del", "then", "fi", "do", "done",
        "esac", "case", "function", "local", "export", "echo", "end", "begin", "module", "require", "unless", "nil",
        "true", "false", "null"], tripleQuotes: true)
    static let dashFamily = Language(line: ["--"], block: ("/*", "*/"), keywords: [
        "select", "from", "where", "join", "left", "right", "inner", "outer", "full", "cross", "on", "group", "by",
        "order", "having", "limit", "insert", "into", "update", "delete", "create", "table", "view", "as", "and", "or",
        "not", "null", "is", "in", "case", "when", "then", "else", "end", "with", "union", "all", "distinct", "values",
        "set", "drop", "alter", "replace", "over", "partition", "asc", "desc", "between", "like", "exists", "true",
        "false", "local", "function", "return", "if", "for", "while", "do", "nil"], caseInsensitive: true)
    static let data = Language(line: [], block: nil, keywords: ["true", "false", "null"])

    static func language(forExtension ext: String) -> Language? {
        switch ext.lowercased() {
        case "swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "m", "mm", "cpp", "hpp", "cc", "rs", "go",
             "java", "kt", "css", "scss": return cFamily
        case "py", "sh", "zsh", "bash", "rb", "r", "yml", "yaml", "toml", "cfg", "conf", "env", "makefile",
             "dockerfile", "gitignore": return hashFamily
        case "sql", "lua": return dashFamily
        case "json", "jsonl", "ipynb": return data
        default: return nil
        }
    }

    /// Larger files stay plain: coloring them would slow down opening.
    static let limit = 600_000

    static func tokens(_ string: String, _ language: Language) -> [(range: NSRange, kind: Kind)] {
        let text = string as NSString
        let length = text.length
        guard length <= limit else { return [] }
        var out: [(NSRange, Kind)] = []
        var i = 0
        func has(_ s: String, at index: Int) -> Bool {
            let n = (s as NSString).length
            return index + n <= length && text.substring(with: NSRange(location: index, length: n)) == s
        }
        func lineEnd(from index: Int) -> Int {
            let r = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: length - index))
            return r.location == NSNotFound ? length : r.location
        }
        func isWord(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        while i < length {
            let c = text.character(at: i)
            if language.line.contains(where: { has($0, at: i) }) {
                let end = lineEnd(from: i)
                out.append((NSRange(location: i, length: end - i), .comment))
                i = end
            } else if let block = language.block, has(block.open, at: i) {
                let from = i + (block.open as NSString).length
                let r = text.range(of: block.close, options: .literal, range: NSRange(location: from, length: length - from))
                let end = r.location == NSNotFound ? length : NSMaxRange(r)
                out.append((NSRange(location: i, length: end - i), .comment))
                i = end
            } else if language.tripleQuotes, has("\"\"\"", at: i) || has("'''", at: i) {
                let quote = text.substring(with: NSRange(location: i, length: 3))
                let r = text.range(of: quote, options: .literal, range: NSRange(location: i + 3, length: length - i - 3))
                let end = r.location == NSNotFound ? length : NSMaxRange(r)
                out.append((NSRange(location: i, length: end - i), .string))
                i = end
            } else if c == 34 || c == 39 || c == 96 {   // " ' `
                // A quote inside a word (don't, it's) isn't a string.
                if c == 39, i > 0, isWord(text.character(at: i - 1)) { i += 1; continue }
                var j = i + 1
                while j < length {
                    let d = text.character(at: j)
                    if d == 92 { j += 2; continue }          // backslash
                    if d == c { j += 1; break }
                    if d == 10, c != 96 { break }             // only backticks span lines
                    j += 1
                }
                j = min(j, length)
                out.append((NSRange(location: i, length: j - i), .string))
                i = j
            } else if c >= 48 && c <= 57, i == 0 || !isWord(text.character(at: i - 1)) {
                var j = i + 1
                // A decimal point only when a digit follows: `$0.edits` is the number 0, then a name.
                while j < length {
                    let d = text.character(at: j)
                    if isWord(d) || (d == 46 && j + 1 < length && (48...57).contains(text.character(at: j + 1))) { j += 1 } else { break }
                }
                out.append((NSRange(location: i, length: j - i), .number))
                i = j
            } else if isWord(c) {
                var j = i + 1
                while j < length, isWord(text.character(at: j)) { j += 1 }
                let word = text.substring(with: NSRange(location: i, length: j - i))
                if language.keywords.contains(language.caseInsensitive ? word.lowercased() : word) {
                    out.append((NSRange(location: i, length: j - i), .keyword))
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// Colors that read on the theme's terminal background, light or dark.
    static func color(_ kind: Kind, theme: Theme) -> NSColor {
        let dark = (theme.terminalBackground.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.5
        switch kind {
        case .comment: return theme.terminalForeground.withAlphaComponent(0.5)
        case .string: return dark ? NSColor(srgbRed: 0.72, green: 0.85, blue: 0.55, alpha: 1) : NSColor(srgbRed: 0.18, green: 0.48, blue: 0.16, alpha: 1)
        case .number: return dark ? NSColor(srgbRed: 0.96, green: 0.67, blue: 0.45, alpha: 1) : NSColor(srgbRed: 0.72, green: 0.38, blue: 0.05, alpha: 1)
        case .keyword: return dark ? NSColor(srgbRed: 0.76, green: 0.6, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.5, green: 0.2, blue: 0.72, alpha: 1)
        }
    }

    static func apply(_ language: Language, to storage: NSTextStorage, theme: Theme) {
        storage.beginEditing()
        for token in tokens(storage.string, language) {
            storage.addAttribute(.foregroundColor, value: color(token.kind, theme: theme), range: token.range)
        }
        storage.endEditing()
    }
}

/// Line numbers beside a code file's text, drawn only for the lines on screen.
final class LineNumberRuler: NSRulerView {
    var theme: Theme? { didSet { needsDisplay = true } }
    private var starts: [Int]?
    private var observers: [NSObjectProtocol] = []

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            self?.textChanged()
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        })
    }

    required init(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    func textChanged() {
        starts = nil
        let lines = currentStarts().count
        let digits = max(3, String(lines).count)
        let width = ("8" as NSString).size(withAttributes: [.font: Self.font]).width
        let thickness = ceil(CGFloat(digits) * width + 14)
        if ruleThickness != thickness { ruleThickness = thickness }
        needsDisplay = true
    }

    private func currentStarts() -> [Int] {
        if let starts { return starts }
        let made = LineIndex.starts(((clientView as? NSTextView)?.string ?? "") as NSString)
        starts = made
        return made
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text = clientView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer else { return }
        (theme?.terminalBackground ?? .textBackgroundColor).setFill()
        bounds.fill()
        let string = text.string as NSString
        guard string.length > 0 else { return }
        let starts = currentStarts()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: (theme?.terminalForeground ?? .labelColor).withAlphaComponent(0.35)]
        let visible = text.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let origin = convert(NSPoint.zero, from: text)
        var line = LineIndex.line(at: chars.location, starts: starts)
        while line <= starts.count {
            let start = starts[line - 1]
            guard start < string.length, start <= NSMaxRange(chars) else { break }
            let glyph = layout.glyphIndexForCharacter(at: start)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = origin.y + text.textContainerInset.height + fragment.minY + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            line += 1
        }
    }
}
