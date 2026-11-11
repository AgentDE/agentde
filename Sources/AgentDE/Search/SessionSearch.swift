import AppKit
import SwiftTerm
import SwiftUI

/// Search across sessions (⌘⇧F): every open tab's Claude transcript (your prompts and Claude's replies, the
/// whole history including compacted parts) or, for plain shells, the terminal scrollback; optionally also
/// recent sessions that aren't open. Results stream in per session; picking one jumps there.
@Observable
final class SessionSearch {
    struct Hit: Identifiable {
        let id: String
        let role: SearchEntry.Role
        let snippet: String
        let timestamp: Date?
        /// The whole message, for when the terminal no longer shows it.
        var text = ""
    }

    struct Section: Identifiable {
        enum Source { case tab(UUID), recent(RecentSession) }
        let id: String
        let source: Source
        let title: String
        let subtitle: String
        let color: SwiftUI.Color?
        let hits: [Hit]
        let total: Int
        var newest: Date? { hits.compactMap(\.timestamp).max() }
    }

    var query = "" { didSet { if query != oldValue { schedule() } } }
    var includeRecent = false { didSet { if includeRecent != oldValue { schedule() } } }
    var sections: [Section] = []
    var progress: (done: Int, total: Int)?

    @ObservationIgnored weak var store: Store?
    /// One index and one queue for every search (⌘⇧F and the sidebar box), so transcripts are read and held once.
    private static let sharedIndex = TranscriptIndex()
    private static let sharedQueue = DispatchQueue(label: "agentde.search", qos: .userInitiated)
    @ObservationIgnored private var index: TranscriptIndex { Self.sharedIndex }
    @ObservationIgnored private var queue: DispatchQueue { Self.sharedQueue }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: DispatchWorkItem?

    private struct Source {
        let id: String
        let source: Section.Source
        let title: String
        let subtitle: String
        let color: SwiftUI.Color?
        let sessionId: String?
        let cwd: String
        let scrollback: [String]?
        /// The session is a Codex thread (its log, not a Claude transcript).
        var codex = false
    }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.run() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func run() {
        guard let store else { return }
        generation += 1
        let gen = generation
        let terms = SearchMatch.terms(query)
        guard terms.contains(where: { $0.count >= 2 }) else {
            sections = []
            progress = nil
            return
        }
        // Snapshot what to search on the main thread; the scan itself runs in the background.
        var sources: [Source] = []
        for group in store.groups {
            let color = SwiftUI.Color(nsColor: store.groupColor(group))
            for tab in group.tabs where tab.kind != .command {
                let codex = tab.kind == .codex
                let session = codex ? tab.codexSessionId : tab.claudeSessionId
                sources.append(Source(id: tab.id.uuidString, source: .tab(tab.id), title: store.title(for: tab),
                                      subtitle: group.name, color: color, sessionId: session, cwd: tab.cwd,
                                      scrollback: session == nil ? store.terminals.scrollback(tab.id) : nil, codex: codex))
            }
        }
        if includeRecent {
            let open = Set(sources.compactMap(\.sessionId))
            // Claude transcripts and Codex session logs alike.
            for recent in store.recentSessions where !open.contains(recent.sessionId) {
                sources.append(Source(id: recent.sessionId, source: .recent(recent), title: recent.name,
                                      subtitle: "recent · " + (recent.cwd as NSString).lastPathComponent, color: nil,
                                      sessionId: recent.sessionId, cwd: recent.cwd, scrollback: nil, codex: recent.agent == .codex))
            }
        }
        progress = (0, sources.count)
        sections = []
        let sessionIds = Set(sources.compactMap(\.sessionId))
        queue.async { [weak self] in
            guard let self else { return }
            self.index.retainOnly(sessionIds: sessionIds)
            var found: [Section] = []
            for (i, source) in sources.enumerated() {
                if self.isStale(gen) { return }
                if let section = self.search(source, terms) { found.append(section) }
                let snapshot = found.sorted { ($0.newest ?? .distantPast) > ($1.newest ?? .distantPast) }
                let done = i + 1
                // Stream results as each session finishes.
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.sections = snapshot
                    self.progress = done == sources.count ? nil : (done, sources.count)
                }
            }
        }
    }

    private func isStale(_ gen: Int) -> Bool {
        DispatchQueue.main.sync { generation != gen }
    }

    private func search(_ source: Source, _ terms: [String]) -> Section? {
        var matches: [SearchEntry] = []
        if let sessionId = source.sessionId {
            matches = index.entries(sessionId: sessionId, cwd: source.cwd, codex: source.codex).filter { SearchMatch.matches($0, terms) }
        } else if let lines = source.scrollback {
            for (i, line) in lines.enumerated() where !line.isEmpty {
                let lower = line.lowercased()
                if terms.allSatisfy({ lower.contains($0) }) {
                    matches.append(SearchEntry(role: .terminal, text: line, lower: lower, timestamp: nil, order: i))
                }
            }
        }
        guard !matches.isEmpty else { return nil }
        let newestFirst = matches.sorted { $0.order > $1.order }
        let hits = newestFirst.prefix(6).map { entry in
            Hit(id: "\(source.id)#\(entry.order)", role: entry.role, snippet: SearchMatch.snippet(entry.text, terms),
                timestamp: entry.timestamp, text: entry.text)
        }
        return Section(id: source.id, source: source.source, title: source.title, subtitle: source.subtitle,
                       color: source.color, hits: Array(hits), total: matches.count)
    }

    /// Jumps to a result: selects the tab, or resumes a recent session, then highlights the match in the terminal.
    func open(_ section: Section) {
        guard let store else { return }
        store.searchOpen = false
        let term = SearchMatch.terms(query).max { $0.count < $1.count } ?? query
        switch section.source {
        case .tab(let id):
            store.selectTab(id)
            let query = self.query
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Compacted away or scrolled past the terminal's history: show the matching messages instead.
                if !store.terminals.reveal(id, term: term) { Self.showMatches(section, query: query, in: id, store: store) }
            }
        case .recent(let recent):
            let group = store.groups.first { $0.dir == recent.cwd }?.id ?? store.selectedGroupID
            if let group { store.resumeRecentSession(recent, in: group) }
        }
    }
}

extension SessionSearch {
    /// The matching messages as a small Markdown page in the tab's viewer: what a search result jumps to when the
    /// terminal no longer has the text.
    static func showMatches(_ section: Section, query: String, in tab: UUID, store: Store) {
        let stamp = DateFormatter()
        stamp.dateFormat = "MMM d, HH:mm"
        var page = "# “\(query)” in \(section.title)\n\n"
        for hit in section.hits {
            let who = hit.role == .you ? "You" : hit.role == .codex ? "Codex" : hit.role == .claude ? "Claude" : "Terminal"
            page += "**\(who)**" + (hit.timestamp.map { " · " + stamp.string(from: $0) } ?? "") + "\n\n" + hit.text + "\n\n---\n\n"
        }
        if section.total > section.hits.count { page += "_\(section.total - section.hits.count) more matches, older._\n" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentde-search", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(tab.uuidString.prefix(8))-matches.md")
        guard (try? page.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        store.openInViewer(file.path, tab: tab)
    }
}

extension TerminalRegistry {
    /// A tab's scrollback as text, for searching. Nil if the tab's terminal hasn't started.
    func scrollback(_ id: UUID) -> [String]? {
        guard let session = session(id), session.started else { return nil }
        // All the history the terminal keeps (Settings → Terminal), not a fixed slice.
        return session.view.getTerminal().scrollbackLines(last: max(5_000, store?.settings.scrollbackLines ?? 10_000))
    }

    /// Scrolls a tab's terminal to the most recent occurrence of `term` and selects it.
    /// Highlights the latest occurrence of `term` in the tab's terminal; false when the terminal doesn't have it.
    @discardableResult
    func reveal(_ id: UUID, term: String) -> Bool {
        guard let view = session(id)?.view, !term.isEmpty else { return false }
        view.clearSearch()
        return view.findPrevious(term)
    }

    /// Drives the terminal's built-in find bar (⌘F, ⌘G, ⌘⇧G).
    func find(_ id: UUID, _ action: NSTextFinder.Action) {
        guard let view = session(id)?.view else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        view.window?.makeFirstResponder(view)
        view.performTextFinderAction(item)
    }
}
