import Foundation

/// One scratch folder per launch, swept at the next (docs/17 §5 theme 7).
///
/// Clipboard imports, recording posters, compressed copies and name-preserving links for
/// drags all used to go straight into `$TMPDIR` and were never removed. Everything
/// short-lived now goes under one folder that belongs to this launch; the next launch
/// deletes every folder but its own, so a crash leaks nothing for longer than one run.
///
/// `$TMPDIR` rather than Application Support: the system may also purge it, which is right
/// for bytes nothing depends on after the process exits. Nothing that must survive a
/// relaunch — a staged capture, a pin — belongs here.
public struct LaunchScratch: Sendable {
    /// Where every launch's folder lives.
    public let root: URL
    /// This launch's folder.
    public let directory: URL

    public init(root: URL, launchID: String = UUID().uuidString) {
        self.root = root
        directory = root.appendingPathComponent(launchID, isDirectory: true)
    }

    /// The agent's scratch, for the life of the process.
    ///
    /// Scoped by bundle identifier so the editor — a separate app with its own launches —
    /// never sweeps a folder the agent is still using, or the other way round.
    public static let current = LaunchScratch(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "Kadr").scratch", isDirectory: true)
    )

    /// A fresh path in this launch's folder. `name` is kept as the last path component, in
    /// a subfolder of its own, so two files with the same name never collide — which is
    /// what lets a hash-named library file be handed out under its real name.
    public func url(named name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    /// `source` under `name`, without copying the bytes when the volume allows it.
    ///
    /// A hard link costs nothing for a multi-gigabyte recording and dies with the sweep; a
    /// copy is the fallback across volumes.
    public func link(_ source: URL, named name: String) throws -> URL {
        let destination = try url(named: name)
        do {
            try FileManager.default.linkItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    /// Deletes every earlier launch's folder. Returns how many went.
    @discardableResult
    public func sweepPreviousLaunches() -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for entry in entries where entry.standardizedFileURL != directory.standardizedFileURL {
            if (try? manager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
