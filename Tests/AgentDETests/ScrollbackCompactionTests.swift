import Foundation
import Testing
@testable import SwiftTerm

/// AgentDE's SwiftTerm patch: scrollback lines keep only their content, with the trailing run of
/// identical cells implied. Reads must be unchanged and writes must expand the line again.
@Suite("Compact scrollback lines")
struct ScrollbackCompactionTests {
    final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// Every cell of `a` and `b` is identical, read through the public subscript.
    func same(_ a: BufferLine, _ b: BufferLine) -> Bool {
        a.count == b.count && (0..<a.count).allSatisfy { a[$0].isSameCell(as: b[$0]) }
    }

    /// A line with text, a wide character, a colored run and blank tail.
    func sampleLine(cols: Int = 120) -> BufferLine {
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: cols, rows: 4, scrollback: 0))
        terminal.feed(text: "hello \u{1b}[1;31mred\u{1b}[0m 日本 \u{1b}[42mgreen\u{1b}[0m end")
        return BufferLine(from: terminal.buffer.lines[0])
    }

    @Test func compactingKeepsEveryCell() {
        let original = sampleLine()
        let compact = BufferLine(from: original)
        compact.compact()
        #expect(compact.isCompacted)
        #expect(same(original, compact))
        #expect(compact.translateToString() == original.translateToString())
        #expect(compact.translateToString(trimRight: true) == original.translateToString(trimRight: true))
        #expect(compact.translateToString(skipNullCellsFollowingWide: true) == original.translateToString(skipNullCellsFollowingWide: true))
        #expect(compact.getTrimmedLength() == original.getTrimmedLength())
        #expect(compact.hasAnyContent() && compact.hasContent(index: 0) && !compact.hasContent(index: 119))
        #expect(compact[500].isSameCell(as: original[500]))   // past the width: the last cell, as before
    }

    @Test func aColoredTailIsKeptAsTheTail() {
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: 100, rows: 4, scrollback: 0))
        terminal.feed(text: "x\u{1b}[44m\u{1b}[K")   // erase to end of line with a blue background
        let original = BufferLine(from: terminal.buffer.lines[0])
        let compact = BufferLine(from: original)
        compact.compact()
        #expect(compact.isCompacted && same(original, compact))
        #expect(compact[99].attribute == original[99].attribute)
    }

    @Test func writesAndResizesExpandFirst() {
        let original = sampleLine()
        let compact = BufferLine(from: original)
        compact.compact()
        var cell = original[0]
        cell.code = 90   // "Z"
        original[110] = cell
        compact[110] = cell
        #expect(!compact.isCompacted && same(original, compact))

        compact.compact()
        original.resize(cols: 160, fillData: CharData.Null)
        compact.resize(cols: 160, fillData: CharData.Null)
        #expect(same(original, compact))
        compact.compact()
        original.resize(cols: 40, fillData: CharData.Null)
        compact.resize(cols: 40, fillData: CharData.Null)
        #expect(same(original, compact))
    }

    @Test func copiesFromAndIntoCompactedLines() {
        let original = sampleLine()
        let compact = BufferLine(from: original)
        compact.compact()
        let copy = BufferLine(cols: 120)
        copy.copyFrom(line: compact)
        #expect(same(copy, original))
        let clone = BufferLine(from: compact)
        #expect(same(clone, original))
        let target = BufferLine(from: original)
        target.compact()
        target.copyFrom(compact, srcCol: 0, dstCol: 2, len: 20)
        let expected = BufferLine(from: original)
        expected.copyFrom(original, srcCol: 0, dstCol: 2, len: 20)
        #expect(same(target, expected))
    }

    /// A recycled scrollback line (the oldest one, reused for a new row) is cleared and rewritten.
    @Test func recycledLinesClearAndRewrite() {
        let line = sampleLine()
        line.compact()
        line.clear(with: CharData.defaultAttr)
        #expect(!line.isCompacted && !line.hasAnyContent())
        line.insertCells(pos: 0, n: 3, rightMargin: 119, fillData: CharData.Null)
        line.replaceCells(start: 0, end: 5, fillData: CharData(attribute: CharData.defaultAttr))
        line.fill(with: CharData.Null, atCol: 5, len: 10)
        line.deleteCells(pos: 0, n: 2, rightMargin: 119, fillData: CharData.Null)
        #expect(line.count == 120)
    }

    @Test func aTerminalCompactsItsScrollbackAndReadsTheSameText() {
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: 140, rows: 10, scrollback: 500))
        var expected: [String] = []
        for i in 0..<300 {
            let text = i % 7 == 0 ? "\u{1b}[33mwarn\u{1b}[0m line \(i) 日本語" : "line \(i)"
            expected.append(i % 7 == 0 ? "warn line \(i) 日本語" : "line \(i)")
            terminal.feed(text: text + "\r\n")
        }
        // A long line that soft-wraps across two rows.
        let long = String(repeating: "abcdefghij", count: 20)
        terminal.feed(text: long + "\r\n")
        for i in 0..<12 { terminal.feed(text: "tail \(i)\r\n") }

        let buffer = terminal.buffer
        let history = (0..<buffer.yBase).map { buffer.lines[$0] }
        #expect(history.count > 250)
        #expect(history.filter(\.isCompacted).count > history.count * 9 / 10)

        // The reader keeps the empty cell after a wide character as "\0" (SwiftTerm's behavior, compacted or not).
        let text = terminal.scrollbackLines().map { $0.replacingOccurrences(of: "\0", with: "") }
        for line in expected.suffix(200) {
            #expect(text.contains(line), "\(line)")
        }
        let joined = text.joined(separator: "\n")
        #expect(joined.contains(long) || joined.replacingOccurrences(of: "\n", with: "").contains(long))

        // Reflow on resize rewrites history lines: the text survives.
        terminal.resize(cols: 70, rows: 10)
        terminal.resize(cols: 140, rows: 10)
        let after = terminal.scrollbackLines().map { $0.replacingOccurrences(of: "\0", with: "") }
        for line in expected.suffix(200) {
            #expect(after.contains(line), "\(line) after resize")
        }
    }
}
