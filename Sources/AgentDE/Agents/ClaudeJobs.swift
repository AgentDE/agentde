import Foundation

extension Store {
    /// A `/fork`'s parent session, from its background job's record (`~/.claude/jobs/<job>/state.json`).
    static func forkParent(job: String, claudeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")) -> String? {
        guard let job = SafeID.job(job) else { return nil }
        let url = claudeDirectory.appendingPathComponent("jobs").appendingPathComponent(job).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return SafeID.session(object["forkParentSessionId"] as? String)
    }
}
