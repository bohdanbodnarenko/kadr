import AppKit
import Foundation
import SettingsKit
import Testing
@testable import Kadr

@MainActor
private final class FakeDesktop: DesktopAppearanceApplying {
    var iconsVisible = true
    var widgetsHidden = false
    var wallpapers: [CGDirectDisplayID: URL] = [1: URL(fileURLWithPath: "/tmp/original.png")]
    var applied: [(CGDirectDisplayID, URL)] = []
    /// Whether icons were still visible when a wallpaper was applied.
    var iconsVisibleAtWallpaper: [Bool] = []
    var legacyRestores = 0

    func restoreLegacyIconHide() {
        legacyRestores += 1
    }

    func currentWallpaperURLs() -> [CGDirectDisplayID: URL] {
        wallpapers
    }

    func applyWallpaper(_ url: URL, screenID: CGDirectDisplayID) {
        wallpapers[screenID] = url
        applied.append((screenID, url))
        iconsVisibleAtWallpaper.append(iconsVisible)
    }

    func restoreWallpapers(_ urls: [CGDirectDisplayID: URL]) {
        wallpapers = urls
    }
}

@MainActor
@Suite("Desktop hygiene")
struct DesktopHygieneTests {
    @Test("A user hide persists and is re-asserted after a simulated crash")
    func userHideReasserts() {
        let storeName = UUID().uuidString
        let store = UserDefaults(suiteName: storeName) ?? .standard
        store.removePersistentDomain(forName: storeName)
        let appearance = FakeDesktop()
        let settings = AppSettings(store: store)
        let hygiene = DesktopHygieneController(settings: settings, appearance: appearance, store: store)

        hygiene.toggleUserHide()
        #expect(appearance.iconsVisible == false)
        #expect(appearance.widgetsHidden)
        #expect(settings.desktopIconsHidden)

        // A new controller on the same store is a relaunch.
        let appearance2 = FakeDesktop()
        appearance2.iconsVisible = true
        appearance2.widgetsHidden = false
        let settings2 = AppSettings(store: store)
        let relaunched = DesktopHygieneController(settings: settings2, appearance: appearance2, store: store)
        relaunched.reassertOnLaunch()

        #expect(appearance2.iconsVisible == false)
        #expect(appearance2.widgetsHidden)
    }

    /// docs/18 SH-4: the icon cover pictures the wallpaper, so the capture fill goes first.
    @Test("A capture swaps the wallpaper before covering the icons")
    func wallpaperBeforeCover() {
        let storeName = UUID().uuidString
        let store = UserDefaults(suiteName: storeName) ?? .standard
        store.removePersistentDomain(forName: storeName)
        let appearance = FakeDesktop()
        let settings = AppSettings(store: store)
        settings.hideDesktopDuringCapture = true
        settings.captureWallpaper = .black
        let hygiene = DesktopHygieneController(settings: settings, appearance: appearance, store: store)

        hygiene.beginCapture()
        #expect(appearance.iconsVisibleAtWallpaper == [true])
        #expect(appearance.iconsVisible == false)
        hygiene.endCapture()
        #expect(appearance.iconsVisible)
    }

    @Test("Launch undoes a Finder hide left by an earlier build")
    func legacyRestoredOnLaunch() {
        let store = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let appearance = FakeDesktop()
        let hygiene = DesktopHygieneController(
            settings: AppSettings(store: store),
            appearance: appearance,
            store: store
        )
        hygiene.reassertOnLaunch()
        #expect(appearance.legacyRestores == 1)
    }

    @Test("Ending a recording does not unhide a user hide")
    func recordingDoesNotOverrideUser() {
        let appearance = FakeDesktop()
        let store = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let settings = AppSettings(store: store)
        let hygiene = DesktopHygieneController(settings: settings, appearance: appearance, store: store)

        hygiene.toggleUserHide()
        settings.hideDesktopDuringRecording = true
        hygiene.beginRecording()
        hygiene.endRecording()

        #expect(appearance.iconsVisible == false)
        #expect(settings.desktopIconsHidden)
    }

    @Test("A recording hide restores Finder after the recording ends")
    func recordingHideRestores() {
        let appearance = FakeDesktop()
        let store = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let settings = AppSettings(store: store)
        settings.hideDesktopDuringRecording = true
        let hygiene = DesktopHygieneController(settings: settings, appearance: appearance, store: store)

        hygiene.beginRecording()
        #expect(appearance.iconsVisible == false)
        hygiene.endRecording()
        #expect(appearance.iconsVisible)
        #expect(appearance.widgetsHidden == false)
    }

    @Test("A crash mid-recording restores icons because the session did not survive")
    func crashDuringRecordingRestores() {
        let storeName = UUID().uuidString
        let store = UserDefaults(suiteName: storeName) ?? .standard
        store.removePersistentDomain(forName: storeName)
        let appearance = FakeDesktop()
        let settings = AppSettings(store: store)
        settings.hideDesktopDuringRecording = true
        let hygiene = DesktopHygieneController(settings: settings, appearance: appearance, store: store)
        hygiene.beginRecording()
        #expect(appearance.iconsVisible == false)

        let appearance2 = FakeDesktop()
        appearance2.iconsVisible = false
        appearance2.widgetsHidden = true
        let settings2 = AppSettings(store: store)
        let relaunched = DesktopHygieneController(settings: settings2, appearance: appearance2, store: store)
        relaunched.reassertOnLaunch()

        #expect(appearance2.iconsVisible)
        #expect(appearance2.widgetsHidden == false)
    }

    @Test("A leftover wallpaper override is restored on launch")
    func wallpaperRestoredAfterCrash() {
        let storeName = UUID().uuidString
        let store = UserDefaults(suiteName: storeName) ?? .standard
        store.removePersistentDomain(forName: storeName)
        let appearance = FakeDesktop()
        let original = appearance.wallpapers
        let settings = AppSettings(store: store)
        settings.captureWallpaper = .black
        let hygiene = DesktopHygieneController(settings: settings, appearance: appearance, store: store)

        hygiene.beginCapture()
        #expect(appearance.wallpapers[1] != original[1])

        let appearance2 = FakeDesktop()
        appearance2.wallpapers = appearance.wallpapers
        let settings2 = AppSettings(store: store)
        let relaunched = DesktopHygieneController(settings: settings2, appearance: appearance2, store: store)
        relaunched.reassertOnLaunch()

        #expect(appearance2.wallpapers[1] == original[1])
    }
}
