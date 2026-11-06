import Foundation

/// What a tab's viewer has shown, newest first: its title menu lists it, and ⌘[ and ⌘] step through it.
enum ViewerHistory {
    static let limit = 10

    /// `history` with `item` moved (or added) to the front, at most `limit` long.
    static func recording(_ item: String, in history: [String]?) -> [String] {
        Array(([item] + (history ?? []).filter { $0 != item }).prefix(limit))
    }

    /// `history` after following a link from `current` to `item`: what's newer than `current` is dropped first.
    static func following(_ item: String, from current: String?, in history: [String]?) -> [String] {
        let history = history ?? []
        let ahead = current.flatMap { history.firstIndex(of: $0) } ?? 0
        return recording(item, in: Array(history.dropFirst(ahead)))
    }

    /// The item `step` places from `current` (+1 older, -1 newer). With nothing shown, going back reopens the
    /// newest. Nil at either end.
    static func step(from current: String?, in history: [String]?, by step: Int) -> String? {
        let history = history ?? []
        guard let current, let index = history.firstIndex(of: current) else { return step > 0 ? history.first : nil }
        let target = index + step
        return history.indices.contains(target) ? history[target] : nil
    }
}
