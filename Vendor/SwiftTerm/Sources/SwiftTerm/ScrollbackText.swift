// AgentDE addition (see PATCHES.md): read the whole buffer, scrollback included, as text.
extension Terminal {
    /// The last `last` lines of the active buffer (all of them by default), oldest first, trailing blanks trimmed.
    public func scrollbackLines(last: Int = .max) -> [String] {
        var result: [String] = []
        let count = buffer.lines.count
        let start = max(0, count - last)
        result.reserveCapacity(count - start)
        for i in start..<count {
            result.append(buffer.lines[i].translateToString(trimRight: true))
        }
        return result
    }
}
