import AppKit

/// Where a ⌘-clicked link goes.
enum LinkTarget: Equatable {
    /// A website: the default browser.
    case web(URL)
    /// A page served on this Mac (localhost and friends): the tab's viewer.
    case localWeb(URL)
    /// A Claude artifact, or a page an extension's link rule claims: the tab's viewer, named by its canonical
    /// link and loaded from `ViewerLinks.openURL`.
    case artifact(URL)
    /// A path or `file://` URL, not yet resolved against the tab's folders.
    case file(String)

    static func classify(_ link: String) -> LinkTarget {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme != "file" else { return .file(link) }
        if scheme == "http" || scheme == "https", let host = url.host?.lowercased(),
           ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) || host.hasSuffix(".localhost") {
            return .localWeb(url)
        }
        if let canonical = ViewerLinks.canonical(link), ViewerLinks.isViewerLink(canonical), let artifact = URL(string: canonical) {
            return .artifact(artifact)
        }
        return .web(url)
    }
}

/// ⌘-clicked links in terminals: local files, local pages and artifacts open in the tab's viewer, other
/// websites in the browser; ⌥⌘-click opens them in their default app instead.
extension Store {
    func openLink(_ link: String, fromTab id: UUID) {
        let owner = tab(id)
        let defaultApp = NSEvent.modifierFlags.contains(.option)
        let hasViewer = owner.map { [.claude, .codex, .shell].contains($0.kind) } ?? false
        switch LinkTarget.classify(link) {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .localWeb(let url), .artifact(let url):
            if defaultApp || !hasViewer { NSWorkspace.shared.open(url) } else if let owner { openInViewer(url.absoluteString, tab: owner.id) }
        case .file(let path):
            guard let owner, let (g, _) = locate(owner.id) else { return }
            guard let file = Store.resolveFileLink(path, relativeTo: [owner.cwd, groups[g].dir]) else {
                DebugLog.log("link not found: \(link)", "link")
                NSSound.beep()
                return
            }
            if defaultApp || !hasViewer { NSWorkspace.shared.open(file) } else { openInViewer(file.path, tab: owner.id) }
        }
    }

    /// Turns a link into an existing file: `file://` URLs, absolute or `~` paths, or paths relative to the
    /// tab's folder (then the group's). A trailing `:line` or `:line:col` is ignored. The terminal ends a link at a
    /// space, so `Claude outputs/thumbs/compare.html` arrives as `outputs/thumbs/compare.html`: a relative path
    /// that isn't found is also tried inside a folder entry whose name ends in a space and its first part.
    /// A link that ends a sentence (`compare.html.`) is tried again without its trailing punctuation.
    static func resolveFileLink(_ link: String, relativeTo folders: [String]) -> URL? {
        if let found = resolveLink(link, relativeTo: folders) { return found }
        let trimmed = link.replacingOccurrences(of: #"[.,;:!?)\]}'"`]+$"#, with: "", options: .regularExpression)
        if trimmed != link, !trimmed.isEmpty, let found = resolveLink(trimmed, relativeTo: folders) { return found }
        return searchFileLink(trimmed.isEmpty ? link : trimmed, in: folders)
    }

    /// Last resort for a relative path written from some subfolder (`stomp_everything/shots/a.png` living in
    /// `Claude outputs/`), or a bare file name: a Spotlight search inside the folders for a file whose path ends
    /// with it. The most recently changed match wins.
    static func searchFileLink(_ link: String, in folders: [String]) -> URL? {
        guard !link.hasPrefix("~"), URL(string: link)?.isFileURL != true else { return nil }
        let relative = link.hasPrefix("/") ? String(link.dropFirst()) : link
        let name = (relative as NSString).lastPathComponent
        guard !name.isEmpty, name.contains(".") else { return nil }
        let fm = FileManager.default
        var seen = Set<String>()
        let matches = folders.filter { seen.insert($0).inserted }.flatMap { fileSearch(name, $0) }.filter {
            $0.hasSuffix("/" + relative) && fm.fileExists(atPath: $0)
        }
        let newest = matches.max { a, b in
            let da = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
            return da < db
        }
        return newest.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    /// Files named `name` under `folder`, from Spotlight. Replaceable in tests, which can't wait for indexing.
    nonisolated(unsafe) static var fileSearch: (_ name: String, _ folder: String) -> [String] = { name, folder in
        guard FileManager.default.fileExists(atPath: folder) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", folder, "-name", name]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    private static func resolveLink(_ link: String, relativeTo folders: [String]) -> URL? {
        if let found = resolveExactFileLink(link, relativeTo: folders) { return found }
        guard !link.hasPrefix("/"), !link.hasPrefix("~"), URL(string: link)?.isFileURL != true,
              let first = link.split(separator: "/").first.map(String.init) else { return nil }
        let rest = String(link.dropFirst(first.count))
        for folder in folders {
            let entries = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            for entry in entries where entry.hasSuffix(" " + first) {
                if let found = resolveExactFileLink(entry + rest, relativeTo: [folder]) { return found }
            }
        }
        return nil
    }

    private static func resolveExactFileLink(_ link: String, relativeTo folders: [String]) -> URL? {
        var path = link
        if let url = URL(string: link), url.isFileURL { path = url.path }
        path = (path as NSString).expandingTildeInPath
        var attempts = [path]
        if let location = path.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) {
            attempts.append(String(path[..<location.lowerBound]))
        }
        for attempt in attempts {
            // `/artifacts/x.html` is usually a folder of the tab's, not the disk's root: try both.
            let inFolders = folders.map { ($0 as NSString).appendingPathComponent(attempt) }
            let candidates = attempt.hasPrefix("/") ? [attempt] + inFolders : inFolders
            if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                return URL(fileURLWithPath: found).standardizedFileURL
            }
        }
        return nil
    }

    // MARK: Viewer

    /// Shows a file path or local URL in the tab's viewer, above its chat.
    /// `select` brings the tab forward (a click in it does); an agent's request doesn't steal focus.
    func openInViewer(_ item: String, tab id: UUID, select: Bool = true) {
        openInViewer(item, tab: id, select: select, record: true)
    }

    /// `record` puts the item first in the tab's history; stepping back and forward through it doesn't.
    func openInViewer(_ item: String, tab id: UUID, select: Bool, record: Bool) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].viewerItem = item
        if record { groups[g].tabs[t].viewerHistory = ViewerHistory.recording(item, in: groups[g].tabs[t].viewerHistory) }
        groups[g].tabs[t].viewerExpanded = nil
        DebugLog.log("viewer \(id.uuidString.prefix(8)): \((item as NSString).lastPathComponent)", "link")
        if select, groups[g].selectedTabID != id { selectTab(id, focus: false) }
        scheduleSave()
    }

    /// ⌘F: the viewer's find bar when the viewer has focus, fills the tab, or already shows its bar (and the
    /// terminal doesn't have focus); otherwise the terminal's.
    func findInTab() {
        guard let tab = activeTab else { return }
        if viewerTakesFind(tab) {
            viewerFindTab = tab.id
            viewerFindFocus += 1
        } else {
            terminals.find(tab.id, .showFindInterface)
        }
    }

    /// ⌘G and ⌘⇧G: the viewer's next or previous match while its find bar is in use, otherwise the terminal's.
    func findAgain(backwards: Bool) {
        guard let tab = activeTab else { return }
        if viewerFindTab == tab.id, viewerTakesFind(tab) {
            viewerFindBackwards = backwards
            viewerFindStep += 1
        } else {
            terminals.find(tab.id, backwards ? .previousMatch : .nextMatch)
        }
    }

    private func viewerTakesFind(_ tab: TabModel) -> Bool {
        guard let item = tab.viewerItem, ViewerKind.of(item).findable else { return false }
        if terminals.viewers.existing(tab.id)?.hasFocus == true || tab.viewerExpanded == true { return true }
        let terminal = terminals.session(tab.id)?.view
        return viewerFindTab == tab.id && !(terminal.map { $0.window?.firstResponder === $0 } ?? false)
    }

    /// ⌘[ (older) and ⌘] (newer): the active tab's viewer history. Going back with the viewer closed reopens the
    /// last item.
    func stepViewer(_ step: Int) {
        guard let tab = activeTab,
              let item = ViewerHistory.step(from: tab.viewerItem, in: tab.viewerHistory, by: step) else { NSSound.beep(); return }
        openInViewer(item, tab: tab.id, select: false, record: false)
    }

    func forgetViewerItem(_ item: String, tab id: UUID) {
        guard let (g, t) = locate(id) else { return }
        let rest = (groups[g].tabs[t].viewerHistory ?? []).filter { $0 != item }
        groups[g].tabs[t].viewerHistory = rest.isEmpty ? nil : rest
        scheduleSave()
    }

    func closeViewer(_ id: UUID) {
        guard let (g, t) = locate(id), groups[g].tabs[t].viewerItem != nil else { return }
        if viewerFindTab == id { viewerFindTab = nil }
        groups[g].tabs[t].viewerItem = nil
        groups[g].tabs[t].viewerExpanded = nil
        terminals.viewers.remove(id)
        scheduleSave()
        terminals.focus(id)
    }

    func toggleViewerRaw(_ id: UUID) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].viewerRaw = (groups[g].tabs[t].viewerRaw ?? false) ? nil : true
        scheduleSave()
    }

    func toggleViewerExpanded(_ id: UUID) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].viewerExpanded = (groups[g].tabs[t].viewerExpanded ?? false) ? nil : true
        scheduleSave()
    }

    func setViewerHeight(_ id: UUID, _ height: Double) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].viewerHeight = height
        scheduleSave()
    }

    // MARK: Side panel

    func togglePanel(_ id: UUID? = nil) {
        guard let id = id ?? activeTab?.id, let (g, t) = locate(id) else { return }
        groups[g].tabs[t].panelHidden = (groups[g].tabs[t].panelHidden ?? false) ? nil : true
        scheduleSave()
    }

    func setPanelWidth(_ id: UUID, _ width: Double) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].panelWidth = width
        scheduleSave()
    }

    func setPanelSection(_ key: String, open: Bool, in id: UUID) {
        guard let (g, t) = locate(id) else { return }
        groups[g].tabs[t].panelSections = (groups[g].tabs[t].panelSections ?? [:]).merging([key: open]) { $1 }
        scheduleSave()
    }
}
