import AppKit

/// The app icons you can pick in Settings: the PNGs in the bundle's `AppIcons` folder. A build can add its own
/// there, with an `icons.json` (`{"order": [ids], "names": {id: name}}`) for their order and names.
enum AppIcons {
    /// Also the bundle's own icon (Resources/AppIcon.icns), which macOS shows while the app isn't running:
    /// the build's default (`AppBrand.defaultIcon`).
    static let defaultID = AppBrand.defaultIcon

    struct Catalog: Decodable {
        var order: [String]?
        var names: [String: String]?
    }

    static func catalog(resources: URL?) -> Catalog? {
        guard let url = resources?.appendingPathComponent("AppIcons/icons.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// Every icon in `resources`: the catalog's order first, then the rest by name; the default always included.
    static func ids(resources: URL? = Bundle.main.resourceURL) -> [String] {
        let folder = resources?.appendingPathComponent("AppIcons")
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: folder?.path ?? "")) ?? [])
            .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }
        let order = catalog(resources: resources)?.order ?? []
        let ordered = order.filter(found.contains) + found.filter { !order.contains($0) }.sorted()
        return ordered.contains(defaultID) ? ordered : [defaultID] + ordered
    }

    static var allIDs: [String] { ids() }

    static func name(_ id: String, resources: URL? = Bundle.main.resourceURL) -> String {
        catalog(resources: resources)?.names?[id] ?? id.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// The saved choice, or the default if it names an icon this build doesn't have.
    static func resolved(_ id: String, resources: URL? = Bundle.main.resourceURL) -> String {
        ids(resources: resources).contains(id) ? id : defaultID
    }

    static func url(_ id: String, resources: URL? = Bundle.main.resourceURL) -> URL? {
        resources?.appendingPathComponent("AppIcons/\(id).png")
    }

    private static var cache: [String: NSImage] = [:]

    static func image(_ id: String) -> NSImage? {
        if let image = cache[id] { return image }
        guard let url = url(id), let image = NSImage(contentsOf: url) else { return nil }
        cache[id] = image
        return image
    }

    /// Shows the chosen icon in the Dock and the app switcher while the app runs. The default is the bundle's
    /// own icon, so choosing it (or an icon that can't be loaded) clears the override.
    static func apply(_ id: String) {
        let id = resolved(id)
        let image = id == defaultID ? nil : image(id)
        NSApp.applicationIconImage = image
        // The Dock didn't show applicationIconImage (macOS 26), so the tile draws the image itself.
        let tile = NSApp.dockTile
        tile.contentView = image.map {
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.image = $0
            view.imageScaling = .scaleProportionallyUpOrDown
            return view
        }
        tile.display()
        DebugLog.log("app icon \(id): \(id == defaultID ? "the bundle's own" : image.map { "loaded \(Int($0.size.width))pt" } ?? "couldn't load \(url(id)?.path ?? "?")")", "app")
    }
}
