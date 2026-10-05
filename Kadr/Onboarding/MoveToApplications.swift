import AppKit
import CaptureCore
import os
import OverlayKit
import Shared

/// Offers to move Kadr into Applications when it is running from the disk image or from
/// a translocated copy (docs/17 T-SH-2).
///
/// From either place the login item, Sparkle's in-place update, the CLI link and every
/// permission grant attach to a path that disappears: the disk image is ejected, and a
/// translocated copy lives in a random folder macOS recreates on each launch. A tester
/// who grants Screen Recording there is asked again the next day, and reports that Kadr
/// forgot. Done in house, the way LetsMove does it, rather than with a dependency.
@MainActor
enum MoveToApplications {
    static let declinedKey = "app.kadr.declinedMoveToApplications"

    private static let logger = KadrLog.logger(.app)

    /// Where the copy should go: the system Applications folder when it is writable,
    /// otherwise the user's own.
    nonisolated static func destinationFolder(
        systemApplicationsWritable: Bool,
        home: String = NSHomeDirectory()
    ) -> URL {
        systemApplicationsWritable
            ? URL(fileURLWithPath: "/Applications", isDirectory: true)
            : URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications", isDirectory: true)
    }

    /// Asks, and moves if the user agrees. Returns true when this instance is quitting
    /// so the moved copy can take over; `quit` runs once the moved copy has been asked to
    /// start, so the two are never both gone.
    static func offerIfNeeded(defaults: UserDefaults = .standard, quit: @escaping @MainActor () -> Void) -> Bool {
        let bundle = Bundle.main.bundleURL
        let location = RunLocation.classify(bundlePath: bundle.path)
        guard location.shouldOfferMove, !defaults.bool(forKey: declinedKey) else { return false }

        let alert = NSAlert()
        alert.messageText = String(localized: "Move Kadr to the Applications folder?")
        alert.informativeText = location == .diskImage
            ? String(localized: """
            Kadr is running from the disk image. Permissions, updates and launch at login \
            only stick once it is in Applications.
            """)
            : String(localized: """
            macOS is running Kadr from a temporary copy. Permissions, updates and launch at \
            login only stick once it is in Applications.
            """)
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Do Not Move"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        let answer = ActivationJuggler.shared.withTemporaryActivation(
            returningTo: ActivationJuggler.returnTarget()
        ) { alert.runModal() }
        if alert.suppressionButton?.state == .on, answer != .alertFirstButtonReturn {
            defaults.set(true, forKey: declinedKey)
        }
        guard answer == .alertFirstButtonReturn else { return false }

        do {
            let moved = try move(bundle)
            relaunch(from: moved, then: quit)
            return true
        } catch {
            logger.error("Moving to Applications failed: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert(error: error)
            failure.messageText = String(localized: "Kadr could not be moved to Applications.")
            failure
                .informativeText =
                String(localized: "Drag Kadr into the Applications folder in Finder, then open it from there.")
            failure.runModal()
            return false
        }
    }

    /// Whether a copy already in Applications may be replaced: only by the same build or a
    /// newer one. Build numbers compare numerically, part by part; an unreadable one is
    /// replaced, since there is nothing to protect.
    static func shouldReplace(existing: String?, with incoming: String?) -> Bool {
        guard let existing, let incoming else { return true }
        return existing.compare(incoming, options: .numeric) != .orderedDescending
    }

    private static func move(_ bundle: URL) throws -> URL {
        let fileManager = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder = destinationFolder(systemApplicationsWritable: fileManager.isWritableFile(atPath: system.path))
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)

        // An older copy goes to the Trash rather than being deleted: it is the user's. A
        // newer one is kept and opened instead: moving a stale download over an updated
        // install would be a silent downgrade (docs/18 §4.6 P3).
        if fileManager.fileExists(atPath: destination.path) {
            guard Self.shouldReplace(
                existing: Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                with: Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ) else {
                logger.notice("A newer Kadr is already in Applications; opening that one")
                return destination
            }
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: bundle, to: destination)
        // A copy made in code keeps the quarantine flag, and a quarantined app that Finder
        // did not move is translocated again — straight back to where this started.
        removeQuarantine(under: destination)
        logger.notice("Moved Kadr to \(folder.path, privacy: .public)")
        return destination
    }

    private static func removeQuarantine(under root: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(root.path, attribute, XATTR_NOFOLLOW)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for case let url as URL in enumerator {
            removexattr(url.path, attribute, XATTR_NOFOLLOW)
        }
    }

    private static func relaunch(from bundle: URL, then quit: @escaping @MainActor () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // The new copy must not yield to this one, which is about to quit.
        configuration.arguments = [RelaunchHelper.relaunchArgument]
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            if let error {
                KadrLog.logger(.app)
                    .error("Opening the moved copy failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in quit() }
        }
    }
}
