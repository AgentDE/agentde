import Foundation

/// Turns Markdown into HTML for the File Explorer preview: headings, paragraphs, nested lists, task lists,
/// block quotes, fenced code, tables, rules, and inline code, emphasis, strikethrough, links and images.
/// Not a full CommonMark implementation; it covers what agents and people write in docs and notes.
enum MarkdownRenderer {
    static func html(_ markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var listStack: [(tag: String, indent: Int)] = []
        var quote: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>") }
            paragraph = []
        }
        func closeLists(to depth: Int = 0) {
            while listStack.count > depth { out.append("</li></\(listStack.removeLast().tag)>") }
        }
        func flushQuote() {
            if !quote.isEmpty { out.append("<blockquote>" + html(quote.joined(separator: "\n")) + "</blockquote>") }
            quote = []
        }
        func flushAll() { flushParagraph(); closeLists(); flushQuote() }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                out.append("<pre><code\(cls)>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph(); flushQuote()
                // A blank line inside a list keeps the list open only if the next line is indented or a bullet.
                if !listStack.isEmpty, i + 1 < lines.count, listItem(lines[i + 1]) == nil,
                   indentation(lines[i + 1]) == 0 { closeLists() }
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); closeLists()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            } else {
                flushQuote()
            }
            if let level = headingLevel(trimmed) {
                flushAll()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                out.append("<h\(level)>" + inline(text) + "</h\(level)>")
                i += 1
                continue
            }
            if paragraph.isEmpty, listStack.isEmpty, isRule(trimmed) {
                flushAll(); out.append("<hr>"); i += 1
                continue
            }
            // Table: a header row followed by a |---| separator row.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushAll()
                var rows = [cells(trimmed)]
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                var table = "<table><thead><tr>" + rows[0].map { "<th>" + inline($0) + "</th>" }.joined() + "</tr></thead><tbody>"
                for row in rows.dropFirst() { table += "<tr>" + row.map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>" }
                out.append(table + "</tbody></table>")
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                let indent = indentation(line)
                if let top = listStack.last, indent > top.indent {
                    out.append("<\(item.tag)>"); listStack.append((item.tag, indent))
                } else {
                    while let top = listStack.last, indent < top.indent { out.append("</li></\(listStack.removeLast().tag)>") }
                    if let top = listStack.last, top.tag == item.tag {
                        out.append("</li>")
                    } else {
                        if !listStack.isEmpty { out.append("</li></\(listStack.removeLast().tag)>") }
                        out.append("<\(item.tag)>"); listStack.append((item.tag, indent))
                    }
                }
                out.append("<li>" + taskBox(item.text) + inline(stripTask(item.text)))
                i += 1
                continue
            }
            if !listStack.isEmpty, indentation(line) > 0 {
                out.append(" " + inline(trimmed))     // continuation of a list item
                i += 1
                continue
            }
            closeLists()
            paragraph.append(trimmed)
            i += 1
        }
        flushAll()
        return out.joined(separator: "\n")
    }

    // MARK: Inline

    static func inline(_ text: String) -> String {
        // Code spans first, so their contents aren't touched by the other rules.
        var codes: [String] = []
        var s = replace(text, #"`([^`]+)`"#) { groups in
            codes.append("<code>" + escape(groups[1]) + "</code>")
            return "\u{0}\(codes.count - 1)\u{0}"
        }
        s = escape(s)
        s = replace(s, #"!\[([^\]]*)\]\(([^)\s]+)\)"#) { "<img alt=\"\($0[1])\" src=\"\($0[2])\">" }
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        s = replace(s, #"(?<![\"=>])\b(https?://[^\s<]+[^\s<.,;:!?)])"#) { "<a href=\"\($0[1])\">\($0[1])</a>" }
        s = replace(s, #"\*\*(.+?)\*\*|__(.+?)__"#) { "<strong>" + ($0[1].isEmpty ? $0[2] : $0[1]) + "</strong>" }
        s = replace(s, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#) {
            "<em>" + ($0[1].isEmpty ? $0[2] : $0[1]) + "</em>"
        }
        s = replace(s, #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        for (n, code) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{0}\(n)\u{0}", with: code) }
        return s
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Regex replace where `transform` gets the match's capture groups (index 0 is the whole match; missing
    /// optional groups are empty strings).
    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { k -> String in
                let r = match.range(at: k)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    // MARK: Blocks

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && ["-", "*", "_"].contains { mark in compact.allSatisfy { String($0) == mark } }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where t.hasPrefix(bullet) { return ("ul", String(t.dropFirst(2))) }
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = t.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return ("ol", String(rest.dropFirst(2))) }
        }
        return nil
    }

    private static func taskBox(_ text: String) -> String {
        if text.hasPrefix("[ ] ") { return "<input type=\"checkbox\" disabled> " }
        if text.lowercased().hasPrefix("[x] ") { return "<input type=\"checkbox\" checked disabled> " }
        return ""
    }

    private static func stripTask(_ text: String) -> String {
        text.hasPrefix("[ ] ") || text.lowercased().hasPrefix("[x] ") ? String(text.dropFirst(4)) : text
    }
}
