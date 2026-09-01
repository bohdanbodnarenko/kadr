import AppKit
import Foundation
import OverlayKit
import SettingsKit
import Testing
@testable import Kadr

@MainActor
@Suite("Teleprompter composer")
struct TeleprompterComposerTests {
    private func settings() -> AppSettings {
        let suite = UserDefaults(suiteName: "app.kadr.tests.teleprompter-composer.\(UUID().uuidString)")
        return AppSettings(store: suite ?? .standard)
    }

    @Test("The composer excludes itself from captures")
    func panelIsExcluded() {
        let composer = TeleprompterComposer()
        let before = CaptureExclusionRegistry.shared.excludedWindowIDs
        composer.show(settings: settings(), above: nil)
        defer { composer.hide() }
        let added = CaptureExclusionRegistry.shared.excludedWindowIDs.subtracting(before)
        #expect(added.count == 1, "the composer was not registered for capture exclusion")
    }

    @Test("Hiding the composer takes it off the exclusion list")
    func hidingUnregisters() {
        let composer = TeleprompterComposer()
        let before = CaptureExclusionRegistry.shared.excludedWindowIDs
        composer.show(settings: settings(), above: nil)
        composer.hide()
        #expect(!composer.isShowing)
        #expect(CaptureExclusionRegistry.shared.excludedWindowIDs == before)
    }

    @Test("A second toggle closes it")
    func toggleCloses() {
        let composer = TeleprompterComposer()
        let settings = settings()
        composer.toggle(settings: settings, above: nil)
        #expect(composer.isShowing)
        composer.toggle(settings: settings, above: nil)
        #expect(!composer.isShowing)
    }
}
