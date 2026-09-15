import Foundation

/// Recently chosen beautify wallpapers, stored locally (docs/16 ED-16).
///
/// Paths only — never URLs, and never a download. A missing file simply disappears from
/// the row the next time it is asked for.
enum BackdropRecents {
    private static let key = "editor.beautify.backdropRecents"
    private static let limit = 8

    static func load(defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: key) ?? []
        return stored.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func remember(_ path: String, defaults: UserDefaults = .standard) {
        guard !path.isEmpty else { return }
        var paths = load(defaults: defaults).filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > limit {
            paths = Array(paths.prefix(limit))
        }
        defaults.set(paths, forKey: key)
    }
}
