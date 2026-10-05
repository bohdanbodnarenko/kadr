import AppKit
import os
import OverlayKit
import SettingsKit
import Shared

/// Reset All Settings and Remove All Kadr Data (docs/17 T-SH-8, T-DIAG-4).
extension AppDelegate {
    /// The bundle identifiers whose preferences Kadr owns.
    static let ownedPreferenceDomains = ["app.kadr.Kadr", "app.kadr.Kadr.Editor"]

    /// Makes what is on screen match the settings again after a reset.
    ///
    /// Resetting rewrote the stored values and left the live state behind: a hidden
    /// menu-bar icon stayed hidden, overlays stayed in or out of captures, and hidden
    /// desktop icons stayed hidden with nothing left in Settings to bring them back.
    func reapplySettingsAfterReset() {
        statusItemController?.applyMenuBarVisibility(settings.showsMenuBarIcon)
        CaptureVisibility.includesOverlays = settings.includesOverlaysInCaptures
        CaptureExclusionRegistry.shared.refresh()
        desktopHygiene.setUserHide(settings.desktopIconsHidden)
        logger.notice("Settings reset to defaults and re-applied")
    }

    /// Everything Kadr keeps for itself, removed, and then Kadr quits — a clean slate for
    /// reproducing a first-run problem without a script (docs/17 T-DIAG-4).
    ///
    /// What the user saved to their own folders is not Kadr's data and is left alone.
    /// Permissions cannot be revoked from inside the app; `Scripts/uninstall.sh` does that.
    func removeAllKadrData() {
        logger.notice("Removing all Kadr data at the user's request")
        // The desktop goes back to how the user had it before anything is deleted, while
        // the record of how that was still exists.
        desktopHygiene.setUserHide(false)
        desktopHygiene.prepareForTermination()

        for editor in NSRunningApplication.runningApplications(withBundleIdentifier: "app.kadr.Kadr.Editor") {
            editor.terminate()
        }
        _ = CLIInstaller().uninstall()
        // A login item left registered would relaunch the clean slate at the next login
        // (docs/18 SH-5).
        try? loginItem.setEnabled(false)

        let fileManager = FileManager.default
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let owned: [URL] = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Kadr", isDirectory: true),
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("app.kadr.Kadr", isDirectory: true),
            library?.appendingPathComponent("Saved Application State/app.kadr.Kadr.savedState", isDirectory: true),
            library?.appendingPathComponent(
                "Saved Application State/app.kadr.Kadr.Editor.savedState",
                isDirectory: true
            )
        ].compactMap(\.self)
        for url in owned where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Could not remove \(url.lastPathComponent, privacy: .private)")
            }
        }
        for domain in Self.ownedPreferenceDomains {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        // Automation consent lives in the Keychain, not the preferences domain (docs/18 OUT-13).
        KeychainConsentStorage().remove()

        // Nothing may be written back on the way out: pins flushing, the login item,
        // the settings the running process still holds in memory.
        isRemovingAllData = true
        NSApp.terminate(nil)
    }
}
