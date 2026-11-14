import CryptoKit
import Foundation

/// Office and iWork documents (slides, documents, spreadsheets) for the viewer: macOS's Quick Look renders them
/// to an HTML page in a fraction of a second with `qlmanage -p -o`, which the viewer's web view shows at once.
/// The in-app Quick Look view takes many seconds for the same file. Results are cached per file version.
enum OfficePreview {
    static let extensions: Set<String> = ["ppt", "pptx", "pps", "ppsx", "doc", "docx", "xls", "xlsx", "key", "pages", "numbers"]

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppBrand.name).appendingPathComponent("previews")
    }

    /// The page for `file`: from the cache when this version was rendered before, else rendered now (blocking,
    /// up to 30 s; call off the main thread). Nil when Quick Look can't render it.
    static func page(for file: URL, cache: URL = cacheDirectory) -> URL? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = "\(file.path)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes?[.size] as? Int ?? 0)"
        let key = SHA256.hash(data: Data(stamp.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let folder = cache.appendingPathComponent(key)
        let page = folder.appendingPathComponent(file.lastPathComponent + ".qlpreview/Preview.html")
        let pdf = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".pdf")
        let slides = folder.appendingPathComponent("slides.html")
        // Rendered before: whichever way worked.
        for done in [page, pdf, slides] where FileManager.default.fileExists(atPath: done.path) { return done }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { prune(cache, keeping: folder) }
        // 1. Quick Look: fast and faithful, but it gives up on some files (many script-made decks).
        if run("/usr/bin/qlmanage", ["-p", "-o", folder.path, file.path]), FileManager.default.fileExists(atPath: page.path) { return page }
        // 2. LibreOffice, when it's installed: an exact PDF.
        let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        if FileManager.default.isExecutableFile(atPath: soffice),
           run(soffice, ["--headless", "--convert-to", "pdf", "--outdir", folder.path, file.path], timeout: 60),
           FileManager.default.fileExists(atPath: pdf.path) { return pdf }
        // 3. Slide decks: AgentDE's own plain rendering of every slide.
        if ["pptx", "ppsx"].contains(file.pathExtension.lowercased()) { return PptxRenderer.render(file, into: folder) }
        return nil
    }

    /// Runs a program to completion (or `timeout`); whether it finished in time.
    private static func run(_ program: String, _ arguments: [String], timeout: TimeInterval = 30) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: program)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate(); return false }
        return true
    }

    /// Drops renders older than a week, so the cache doesn't grow without end.
    private static func prune(_ cache: URL, keeping: URL) {
        let old = Date().addingTimeInterval(-7 * 86_400)
        for folder in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where folder != keeping {
            if let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < old {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
