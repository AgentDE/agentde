// AgentDE addition (see PATCHES.md): read the whole buffer, scrollback included, as text.
extension Terminal {
    /// The last `last` lines of the active buffer (all of them by default), oldest first, trailing blanks trimmed.
    /// A wide character's second (empty) cell is left out, so `日本` reads as `日本`, not `日\0本`.
    public func scrollbackLines(last: Int = .max) -> [String] {
        var result: [String] = []
        let count = buffer.lines.count
        let start = max(0, count - last)
        result.reserveCapacity(count - start)
        for i in start..<count {
            result.append(buffer.lines[i].translateToString(trimRight: true, skipNullCellsFollowingWide: true))
        }
        return result
    }
}
