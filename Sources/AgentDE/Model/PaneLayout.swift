import Foundation

/// How a group shows several of its tabs at once, tmux style: a tab, or a split of two layouts side by side
/// (`vertical: false`) or one above the other (`vertical: true`), with the first one's share of the space.
indirect enum PaneLayout: Codable, Equatable {
    case tab(UUID)
    case split(vertical: Bool, ratio: Double, first: PaneLayout, second: PaneLayout)

    /// The tabs shown, in reading order (left to right, top to bottom).
    var tabs: [UUID] {
        switch self {
        case .tab(let id): [id]
        case .split(_, _, let first, let second): first.tabs + second.tabs
        }
    }

    /// `target`'s pane split in two, `new` taking the right (or bottom) half.
    func splitting(_ target: UUID, with new: UUID, vertical: Bool) -> PaneLayout {
        switch self {
        case .tab(let id):
            id == target ? .split(vertical: vertical, ratio: 0.5, first: self, second: .tab(new)) : self
        case .split(let v, let ratio, let first, let second):
            .split(vertical: v, ratio: ratio, first: first.splitting(target, with: new, vertical: vertical),
                   second: second.splitting(target, with: new, vertical: vertical))
        }
    }

    /// The layout without `id`'s pane: its sibling takes the space. Nil when nothing is left.
    func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .tab(let tab):
            return tab == id ? nil : self
        case .split(let v, let ratio, let first, let second):
            switch (first.removing(id), second.removing(id)) {
            case (nil, nil): return nil
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (let a?, let b?): return .split(vertical: v, ratio: ratio, first: a, second: b)
            }
        }
    }

    /// `old`'s pane showing `new` instead.
    func replacing(_ old: UUID, with new: UUID) -> PaneLayout {
        switch self {
        case .tab(let id): id == old ? .tab(new) : self
        case .split(let v, let ratio, let first, let second):
            .split(vertical: v, ratio: ratio, first: first.replacing(old, with: new), second: second.replacing(old, with: new))
        }
    }

    /// The split at `path` (false = first, true = second, from the top) with a new ratio.
    func settingRatio(_ ratio: Double, at path: [Bool]) -> PaneLayout {
        guard case .split(let v, let old, let first, let second) = self else { return self }
        guard let step = path.first else { return .split(vertical: v, ratio: min(max(ratio, 0.15), 0.85), first: first, second: second) }
        let rest = Array(path.dropFirst())
        return step ? .split(vertical: v, ratio: old, first: first, second: second.settingRatio(ratio, at: rest))
                    : .split(vertical: v, ratio: old, first: first.settingRatio(ratio, at: rest), second: second)
    }

    /// Only the tabs in `existing`; nil when fewer than two remain (no split to show).
    func pruned(to existing: Set<UUID>) -> PaneLayout? {
        var layout: PaneLayout? = self
        for id in tabs where !existing.contains(id) { layout = layout?.removing(id) }
        guard let layout, layout.tabs.count >= 2 else { return nil }
        return layout
    }
}
