import Foundation

/// Validates ids that end up inside shell commands, so a tampered registry, receipt or transcript file name
/// can't inject shell syntax. Claude session ids are UUIDs; background job ids are short hex strings.
public enum SafeID {
    public static func session(_ id: String?) -> String? {
        guard let id, UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }

    public static func job(_ id: String?) -> String? {
        guard let id, (4...40).contains(id.count), id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return id.lowercased()
    }
}

extension String {
    public var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
