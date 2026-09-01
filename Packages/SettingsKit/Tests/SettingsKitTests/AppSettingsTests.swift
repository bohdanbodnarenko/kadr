import Foundation
import Testing
@testable import SettingsKit

/// A throwaway defaults suite so tests never touch the real preferences.
func makeStore(_ name: String = UUID().uuidString) -> UserDefaults {
    guard let store = UserDefaults(suiteName: name) else {
        fatalError("Could not open a throwaway defaults suite named \(name)")
    }
    store.removePersistentDomain(forName: name)
    return store
}

@Suite("Typed setting keys")
struct SettingKeyTests {
    @Test("An unset key reads its default")
    func unsetKeyReadsDefault() {
        let store = makeStore()
        #expect(store[SettingKeys.filenameTemplate] == "{app}-{date}-{time}")
        #expect(store[SettingKeys.downscaleRetinaCaptures] == false)
        #expect(store[SettingKeys.imageFormat] == .png)
        #expect(store.hasValue(for: SettingKeys.filenameTemplate) == false)
    }

    @Test("Values round-trip through the store")
    func valuesRoundTrip() {
        let store = makeStore()
        store[SettingKeys.filenameTemplate] = "{date}"
        store[SettingKeys.downscaleRetinaCaptures] = true
        store[SettingKeys.imageFormat] = .heic
        store[SettingKeys.schemaVersion] = 7

        #expect(store[SettingKeys.filenameTemplate] == "{date}")
        #expect(store[SettingKeys.downscaleRetinaCaptures] == true)
        #expect(store[SettingKeys.imageFormat] == .heic)
        #expect(store[SettingKeys.schemaVersion] == 7)
        #expect(store.hasValue(for: SettingKeys.filenameTemplate))
    }

    @Test("A raw value the enum no longer knows falls back to the default")
    func unknownRawValueFallsBack() {
        let store = makeStore()
        store.set("bmp", forKey: SettingKeys.imageFormat.name)
        #expect(store[SettingKeys.imageFormat] == .png)
    }

    @Test("A value of the wrong type falls back to the default")
    func wrongTypeFallsBack() {
        let store = makeStore()
        store.set(["not", "a", "string"], forKey: SettingKeys.filenameTemplate.name)
        #expect(store[SettingKeys.filenameTemplate] == "{app}-{date}-{time}")
    }
}

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {
    @Test("Fresh settings expose the docs/03 §8.3 defaults")
    func defaults() {
        let settings = AppSettings(store: makeStore())
        #expect(settings.defaultAction == .copyToClipboard)
        #expect(settings.filenameTemplate == "{app}-{date}-{time}")
        #expect(settings.imageFormat == .png)
        #expect(settings.downscaleRetinaCaptures == false)
        #expect(settings.saveFolderPath.isEmpty)
        #expect(settings.saveFolder == AppSettings.defaultSaveFolder)
    }

    @Test("Mutations write through immediately and survive a reload")
    func mutationsPersist() {
        let store = makeStore()
        let settings = AppSettings(store: store)
        settings.defaultAction = .copyAndSave
        settings.filenameTemplate = "{app}"
        settings.imageFormat = .webp
        settings.downscaleRetinaCaptures = true
        settings.saveFolderPath = "/tmp/kadr-captures"

        let reloaded = AppSettings(store: store)
        #expect(reloaded.defaultAction == .copyAndSave)
        #expect(reloaded.filenameTemplate == "{app}")
        #expect(reloaded.imageFormat == .webp)
        #expect(reloaded.downscaleRetinaCaptures == true)
        #expect(reloaded.saveFolder.path == "/tmp/kadr-captures")
    }

    @Test("Reset restores every default")
    func resetRestoresDefaults() {
        let store = makeStore()
        let settings = AppSettings(store: store)
        settings.defaultAction = .saveToFolder
        settings.filenameTemplate = "x"
        settings.downscaleRetinaCaptures = true
        settings.resetToDefaults()

        #expect(settings.defaultAction == .copyToClipboard)
        #expect(settings.filenameTemplate == "{app}-{date}-{time}")
        #expect(settings.downscaleRetinaCaptures == false)
        #expect(AppSettings(store: store).defaultAction == .copyToClipboard)
    }

    @Test("Constructing settings stamps the current schema version")
    func initMigrates() {
        let store = makeStore()
        _ = AppSettings(store: store)
        #expect(store[SettingKeys.schemaVersion] == SettingsMigrator.currentVersion)
    }
}

@Suite("Settings migration")
struct SettingsMigratorTests {
    @Test("A fresh store is migrated to the current version")
    func freshStore() {
        let store = makeStore()
        #expect(SettingsMigrator.migrate(store) == SettingsMigrator.currentVersion)
        #expect(store[SettingKeys.schemaVersion] == SettingsMigrator.currentVersion)
    }

    @Test("Migration is idempotent")
    func idempotent() {
        let store = makeStore()
        SettingsMigrator.migrate(store)
        SettingsMigrator.migrate(store)
        #expect(SettingsMigrator.migrate(store) == SettingsMigrator.currentVersion)
    }

    @Test("Migration never touches user values")
    func preservesValues() {
        let store = makeStore()
        store[SettingKeys.filenameTemplate] = "{app}-{counter}"
        SettingsMigrator.migrate(store)
        #expect(store[SettingKeys.filenameTemplate] == "{app}-{counter}")
    }

    @Test("A store from a newer build is left alone rather than downgraded")
    func newerStoreIsLeftAlone() {
        let store = makeStore()
        let future = SettingsMigrator.currentVersion + 5
        store[SettingKeys.schemaVersion] = future
        #expect(SettingsMigrator.migrate(store) == future)
        #expect(store[SettingKeys.schemaVersion] == future)
    }

    @Test("Every step declares the version it starts from, with no gaps")
    func stepsFormAChain() {
        var version = 0
        for step in SettingsMigrator.steps.sorted(by: { $0.fromVersion < $1.fromVersion }) {
            #expect(step.fromVersion == version)
            version = step.fromVersion + 1
        }
        #expect(version == SettingsMigrator.currentVersion)
    }
}

@Suite("Retiring the openInEditor default action")
struct DefaultActionMigrationTests {
    @Test("A stored openInEditor becomes copy-to-clipboard rather than silently resetting")
    func migratesOpenInEditor() {
        let store = makeStore()
        store.set(1, forKey: SettingKeys.schemaVersion.name)
        store.set("openInEditor", forKey: SettingKeys.defaultAction.name)

        SettingsMigrator.migrate(store)

        #expect(store[SettingKeys.defaultAction] == .copyToClipboard)
        #expect(store[SettingKeys.schemaVersion] == SettingsMigrator.currentVersion)
    }

    @Test("Other stored actions are left alone")
    func leavesOtherActions() {
        let store = makeStore()
        store.set(1, forKey: SettingKeys.schemaVersion.name)
        store.set("saveToFolder", forKey: SettingKeys.defaultAction.name)

        SettingsMigrator.migrate(store)

        #expect(store[SettingKeys.defaultAction] == .saveToFolder)
    }

    @Test("A fresh store never sees the migration and gets the default")
    func freshStore() {
        let store = makeStore()
        SettingsMigrator.migrate(store)
        #expect(store[SettingKeys.defaultAction] == .copyToClipboard)
    }

    @Test("Default actions describe what they do to the clipboard and the folder", arguments: [
        (DefaultCaptureAction.copyToClipboard, true, false),
        (DefaultCaptureAction.saveToFolder, false, true),
        (DefaultCaptureAction.copyAndSave, true, true),
        (DefaultCaptureAction.overlayOnly, false, false)
    ])
    func actionBehaviour(action: DefaultCaptureAction, copies: Bool, saves: Bool) {
        #expect(action.copiesToClipboard == copies)
        #expect(action.savesToFolder == saves)
    }
}

@MainActor
@Suite("Overlay settings")
struct OverlaySettingsTests {
    @Test("Defaults match doc 03 §2: bottom left, no timeout, five cards")
    func defaults() {
        let settings = AppSettings(store: makeStore())
        #expect(settings.overlayCorner == .bottomLeft)
        #expect(settings.overlayTimeout == .never)
        #expect(settings.overlayMaxVisibleCards == 5)
        #expect(settings.overlayDismissOnDrag)
    }

    @Test("Card width is clamped to something usable")
    func clampsCardWidth() {
        let settings = AppSettings(store: makeStore())
        settings.overlayCardWidth = 10000
        #expect(settings.overlayCardWidth == 420)

        settings.overlayCardWidth = 1
        #expect(settings.overlayCardWidth == 140)
    }

    @Test("The visible card count is clamped too")
    func clampsCardCount() {
        let settings = AppSettings(store: makeStore())
        settings.overlayMaxVisibleCards = 0
        #expect(settings.overlayMaxVisibleCards == 1)

        settings.overlayMaxVisibleCards = 99
        #expect(settings.overlayMaxVisibleCards == 10)
    }

    @Test("Corners know which edges they hug", arguments: [
        (OverlayCorner.bottomLeft, true, true),
        (OverlayCorner.bottomRight, false, true),
        (OverlayCorner.topLeft, true, false),
        (OverlayCorner.topRight, false, false)
    ])
    func cornerEdges(corner: OverlayCorner, leading: Bool, bottom: Bool) {
        #expect(corner.isLeading == leading)
        #expect(corner.isBottom == bottom)
    }
}

@MainActor
@Suite("History settings")
struct HistorySettingsTests {
    @Test("Defaults keep captures forever with a 5 GB cap (docs/03 §5)")
    func defaults() {
        let settings = AppSettings(store: makeStore())
        #expect(settings.historyRetention == .forever)
        #expect(settings.historySizeCap == .gigabytes5)
        #expect(settings.historyRetention.maxAge == nil)
        #expect(settings.historySizeCap.bytes == Int64(5) * 1024 * 1024 * 1024)
    }

    @Test("Retention and the size cap survive a reload")
    func persist() {
        let store = makeStore()
        let settings = AppSettings(store: store)
        settings.historyRetention = .sevenDays
        settings.historySizeCap = .megabytes512

        let reloaded = AppSettings(store: store)
        #expect(reloaded.historyRetention == .sevenDays)
        #expect(reloaded.historySizeCap == .megabytes512)
        #expect(reloaded.historyRetention.maxAge == TimeInterval(7 * 24 * 60 * 60))
    }

    @Test("Reset restores history defaults")
    func reset() {
        let settings = AppSettings(store: makeStore())
        settings.historyRetention = .session
        settings.historySizeCap = .unlimited
        settings.resetToDefaults()
        #expect(settings.historyRetention == .forever)
        #expect(settings.historySizeCap == .gigabytes5)
    }
}

@MainActor
@Suite("Desktop hygiene settings")
struct DesktopHygieneSettingsTests {
    @Test("Desktop hygiene is off until the user asks")
    func defaults() {
        let settings = AppSettings(store: makeStore())
        #expect(settings.desktopIconsHidden == false)
        #expect(settings.hideDesktopDuringCapture == false)
        #expect(settings.hideDesktopDuringRecording == false)
        #expect(settings.captureWallpaper == .none)
        #expect(settings.capturePrecisionCrosshair == false)
    }

    @Test("Desktop hygiene settings survive a reload and a reset")
    func persistAndReset() {
        let store = makeStore()
        let settings = AppSettings(store: store)
        settings.desktopIconsHidden = true
        settings.hideDesktopDuringRecording = true
        settings.captureWallpaper = .black
        settings.capturePrecisionCrosshair = true

        let reloaded = AppSettings(store: store)
        #expect(reloaded.desktopIconsHidden)
        #expect(reloaded.hideDesktopDuringRecording)
        #expect(reloaded.captureWallpaper == .black)
        #expect(reloaded.capturePrecisionCrosshair)

        reloaded.resetToDefaults()
        #expect(reloaded.desktopIconsHidden == false)
        #expect(reloaded.captureWallpaper == .none)
        #expect(reloaded.capturePrecisionCrosshair == false)
    }

    /// The first-capture tip fires once and then never again — a tip that reappears is a
    /// tip that nags.
    @Test("The first-capture tip is remembered as seen")
    func firstCaptureTipIsRemembered() {
        let store = makeStore()
        let settings = AppSettings(store: store)
        #expect(!settings.hasSeenQuickAccessTip, "the tip has to appear for a new user")

        settings.hasSeenQuickAccessTip = true
        #expect(AppSettings(store: store).hasSeenQuickAccessTip, "the tip would come back next launch")
    }

    /// Its own key rather than onboarding's. Onboarding runs before the user has captured
    /// anything, which is the wrong moment to explain a card they have never seen.
    @Test("The tip is tracked separately from onboarding")
    func tipIsSeparateFromOnboarding() {
        let store = makeStore()
        let settings = AppSettings(store: store)
        settings.hasCompletedOnboarding = true

        #expect(!settings.hasSeenQuickAccessTip, "finishing onboarding silently consumed the card tip")
    }
}
