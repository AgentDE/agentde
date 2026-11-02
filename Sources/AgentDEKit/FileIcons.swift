import AppKit
import Quartz
import SwiftUI

public enum FileIcons {
    public static func symbol(for url: URL, isDirectory: Bool, expanded: Bool = false) -> String {
        if isDirectory { return expanded ? "folder.fill" : "folder" }
        switch url.pathExtension.lowercased() {
        case "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "cpp", "h", "java", "kt", "rb", "sh", "zsh", "sql":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rst": return "doc.text"
        case "json", "yml", "yaml", "toml", "ini", "cfg", "plist", "lock": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "icns": return "photo"
        case "mp4", "mov", "webm", "mkv": return "film"
        case "pdf": return "doc.richtext"
        case "html", "htm", "css": return "globe"
        case "csv", "tsv", "parquet", "xlsx": return "tablecells"
        case "ipynb": return "book"
        case "zip", "gz", "tar", "tgz": return "archivebox"
        default: return "doc"
        }
    }
}
