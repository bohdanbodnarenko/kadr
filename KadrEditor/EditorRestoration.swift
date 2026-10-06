import Foundation

/// Which annotation windows come back at the next launch (docs/18 T-ED-7).
///
/// The editor is a separate process that exits with its last window, so AppKit's own
/// restoration never has a chance: quitting with captures open, or a crash, lost the set.
/// Two sources, kept apart because they deserve different treatment:
/// - windows open at quit reopen silently, but only when the system setting "Close windows
///   when quitting an application" is off — the same rule every document app follows;
/// - captures with unsaved, autosaved edits are listed and offered, never reopened unasked.
struct EditorRestoration {
    static let storageKey = "editor.restorableDocuments"
    /// The global preference behind "Close windows when quitting an application".
    static let keepsWindowsKey = "NSQuitAlwaysKeepsWindows"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the user asked macOS to bring windows back after quitting.
    var keepsWindows: Bool {
        defaults.bool(forKey: Self.keepsWindowsKey)
    }

    /// Records the windows open at quit, or forgets them when the user does not keep
    /// windows, so a later change of that setting cannot resurrect an old set.
    func remember(_ documents: [URL]) {
        guard keepsWindows, !documents.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        defaults.set(documents.map(\.path), forKey: Self.storageKey)
    }

    /// The windows to reopen now, read once: the list is cleared as it is read, so a
    /// capture that crashes the editor on open cannot trap it in a relaunch loop.
    func takeRestorable() -> [URL] {
        let paths = defaults.stringArray(forKey: Self.storageKey) ?? []
        defaults.removeObject(forKey: Self.storageKey)
        guard keepsWindows else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Splits launch-time work: what reopens silently and what is offered.
    ///
    /// Already-open captures are left out of both — their own window already asks about
    /// recovery — and a capture that reopens silently is not offered as well.
    static func plan(
        restorable: [URL],
        recoveries: [URL],
        open: Set<URL>,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> (reopen: [URL], offer: [URL]) {
        let openPaths = Set(open.map(\.standardizedFileURL.path))
        var seen = openPaths
        var reopen: [URL] = []
        for url in restorable where exists(url) && seen.insert(url.standardizedFileURL.path).inserted {
            reopen.append(url)
        }
        let offer = recoveries.filter { !seen.contains($0.standardizedFileURL.path) }
        return (reopen, offer)
    }
}
