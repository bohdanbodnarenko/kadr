import Foundation
import Testing
@testable import SettingsKit

/// A throwaway defaults suite so tests never touch the real preferences.
private func makeStore(_ name: String = UUID().uuidString) -> UserDefaults {
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
        settings.defaultAction = .openInEditor
        settings.filenameTemplate = "{app}"
        settings.imageFormat = .webp
        settings.downscaleRetinaCaptures = true
        settings.saveFolderPath = "/tmp/kadr-captures"

        let reloaded = AppSettings(store: store)
        #expect(reloaded.defaultAction == .openInEditor)
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
