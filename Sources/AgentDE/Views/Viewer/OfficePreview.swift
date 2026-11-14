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
        if FileManager.default.fileExists(atPath: page.path) { return page }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        task.arguments = ["-p", "-o", folder.path, file.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(30)
        while task.isRunning, Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate(); return nil }
        prune(cache, keeping: folder)
        return FileManager.default.fileExists(atPath: page.path) ? page : nil
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
