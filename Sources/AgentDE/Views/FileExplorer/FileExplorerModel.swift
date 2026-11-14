import AppKit

/// A File Explorer tab: a lazily loaded folder tree with a Quick Look preview, and a filter that finds
/// any file in the repo by name. Read-only on purpose; editing belongs in Cursor or with Claude.
@Observable
final class FileExplorerModel {
    final class Node: Identifiable {
        let url: URL
        let isDirectory: Bool
        var children: [Node]?
        var id: String { url.path }
        var name: String { url.lastPathComponent }

        init(url: URL, isDirectory: Bool) {
            self.url = url
            self.isDirectory = isDirectory
        }
    }

    let root: URL
    var expanded: Set<String> = []
    var selection: URL? { didSet { if let selection, !Self.isFolder(selection) { previewed = selection } } }
    /// The file the preview shows: the last file selected. Selecting a folder (to open or close it) keeps it.
    private(set) var previewed: URL?
    var filter = "" { didSet { if filter != oldValue { refilter() } } }
    /// Dotfiles always show; this also shows the `noisy` generated folders.
    var showHidden = false { didSet { if showHidden != oldValue { reload() } } }
    private(set) var rows: [(node: Node, depth: Int)] = []
    private(set) var filtered: [String] = []
    @ObservationIgnored private var rootNode: Node
    @ObservationIgnored private var allFiles: [String]?
    @ObservationIgnored private var listGeneration = 0

    /// Folders that are almost never what you're looking for. Hidden unless the eye button is on.
    static let noisy: Set<String> = [".git", "node_modules", ".build", "__pycache__", ".venv", "venv", ".DS_Store",
                                     ".mypy_cache", ".pytest_cache", ".ruff_cache", ".next", "dist", ".turbo", ".idea"]

    init(root: String, selection: String?) {
        self.root = URL(fileURLWithPath: root)
        rootNode = Node(url: self.root, isDirectory: true)
        self.selection = selection.map(URL.init(fileURLWithPath:))
        previewed = self.selection.flatMap { Self.isFolder($0) ? nil : $0 }
        expanded = [self.root.path]
        if let selection {
            // Open the folders leading to the remembered selection.
            var dir = URL(fileURLWithPath: selection).deletingLastPathComponent()
            while dir.path.hasPrefix(self.root.path), dir.path != self.root.path {
                expanded.insert(dir.path)
                dir = dir.deletingLastPathComponent()
            }
        }
        reload()
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Selects a file and opens the folders above it, clearing any filter (used when a link is opened here).
    func reveal(_ url: URL) {
        filter = ""
        var dir = url.deletingLastPathComponent()
        while dir.path.hasPrefix(root.path), dir.path != root.path {
            expanded.insert(dir.path)
            dir = dir.deletingLastPathComponent()
        }
        selection = url
        rebuildRows()
    }

    func reload() {
        rootNode = Node(url: root, isDirectory: true)
        allFiles = nil
        rebuildRows()
        // Build the filter's file list in the background so the first keystroke doesn't wait on git.
        let root = self.root
        listGeneration += 1
        let generation = listGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = Self.listFiles(root)
            DispatchQueue.main.async {
                // An older scan finishing late must not overwrite a newer one.
                guard let self, self.listGeneration == generation else { return }
                self.allFiles = files
                self.refilter()
            }
        }
    }

    func toggle(_ node: Node) {
        guard node.isDirectory else { return }
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        rebuildRows()
    }

    func setExpanded(_ node: Node, _ open: Bool) {
        guard node.isDirectory, expanded.contains(node.id) != open else { return }
        toggle(node)
    }

    private func children(of node: Node) -> [Node] {
        if let cached = node.children { return cached }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: node.url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let nodes = urls
            .filter { showHidden || !Self.noisy.contains($0.lastPathComponent) }
            .map { Node(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        node.children = nodes
        return nodes
    }

    private func rebuildRows() {
        var result: [(Node, Int)] = []
        func walk(_ node: Node, _ depth: Int) {
            for child in children(of: node) {
                result.append((child, depth))
                if child.isDirectory, expanded.contains(child.id) { walk(child, depth + 1) }
            }
        }
        walk(rootNode, 0)
        rows = result
    }

    // MARK: Filter

    /// Every file under the root, relative paths: `git ls-files` (tracked plus untracked, minus ignored) when
    /// it's a repo, else a bounded walk. Built once per explorer, on first use of the filter.
    private static func listFiles(_ root: URL) -> [String] {
        var files: [String] = []
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // -z: raw NUL-separated paths, so names with spaces, quotes, newlines or non-ASCII come through intact.
        git.arguments = ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let out = Pipe()
        git.standardOutput = out
        git.standardError = Pipe()
        if (try? git.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            git.waitUntilExit()
            if git.terminationStatus == 0 {
                var seen = Set<String>()
                files = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { seen.insert($0).inserted }
            }
        }
        if files.isEmpty, let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker {
                if Self.noisy.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false {
                    files.append(String(url.path.dropFirst(root.path.count + 1)))
                }
                if files.count >= 50_000 { break }
            }
        }
        return files
    }

    private func refilter() {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { filtered = []; return }
        let words = query.split(separator: " ").map(String.init)
        filtered = (allFiles ?? [])
            .compactMap { path -> (String, Int)? in
                let lower = path.lowercased()
                guard words.allSatisfy({ lower.contains($0) }) else { return nil }
                // Prefer matches in the file name, then shorter paths.
                let name = (lower as NSString).lastPathComponent
                let score = (words.allSatisfy { name.contains($0) } ? 0 : 1000) + path.count
                return (path, score)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(300)
            .map(\.0)
    }
}
