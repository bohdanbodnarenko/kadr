import Foundation
import Testing
@testable import SettingsKit

/// What happens after a capture (docs/09 U2.2).
///
/// A set rather than a choice, because the options compose: copying and saving are not
/// alternatives, and the old single enum forced people to pick the case that happened to
/// mean both.
@Suite("After-capture matrix")
struct AfterCaptureMatrixTests {
    // MARK: - Composition

    @Test("Actions combine rather than exclude each other")
    func actionsCompose() {
        var matrix = AfterCaptureMatrix()
        matrix[.screenshot] = [.overlay, .copy, .save]

        #expect(matrix[.screenshot].contains(.copy))
        #expect(matrix[.screenshot].contains(.save))
        #expect(matrix[.screenshot].contains(.overlay))
    }

    @Test("The two rows are independent")
    func rowsAreIndependent() {
        var matrix = AfterCaptureMatrix()
        matrix[.screenshot] = [.copy]
        matrix[.recording] = [.save]

        #expect(matrix[.screenshot] == [.copy])
        #expect(matrix[.recording] == [.save])
    }

    /// Nobody wants a two-minute recording on their clipboard, which is why the default
    /// differs by kind at all.
    @Test("The defaults differ by kind, sensibly")
    func defaults() {
        let matrix = AfterCaptureMatrix.standard
        #expect(matrix[.screenshot].contains(.copy))
        #expect(!matrix[.recording].contains(.copy))
        #expect(matrix[.recording].contains(.save))
        #expect(matrix[.screenshot].contains(.overlay))
    }

    // MARK: - Applicability

    /// Offering a button that does nothing is the failure the review found on the cards
    /// themselves (docs/07 M8); the settings pane must not repeat it.
    @Test("Annotating and pinning mean nothing for a recording")
    func recordingApplicability() {
        #expect(!AfterCaptureActions.annotate.applies(to: .recording))
        #expect(!AfterCaptureActions.pin.applies(to: .recording))
        #expect(AfterCaptureActions.openEditor.applies(to: .recording))
    }

    @Test("The trim editor means nothing for a screenshot")
    func screenshotApplicability() {
        #expect(!AfterCaptureActions.openEditor.applies(to: .screenshot))
        #expect(AfterCaptureActions.annotate.applies(to: .screenshot))
        #expect(AfterCaptureActions.pin.applies(to: .screenshot))
    }

    /// A stored contradiction outlives whatever set it, so the row filters on the way in
    /// rather than trusting its callers.
    @Test("A row cannot hold an action that does nothing for its kind")
    func inapplicableActionsAreFilteredOut() {
        var matrix = AfterCaptureMatrix()
        matrix[.recording] = [.overlay, .annotate, .pin, .save]

        #expect(!matrix[.recording].contains(.annotate))
        #expect(!matrix[.recording].contains(.pin))
        #expect(matrix[.recording].contains(.save))
    }

    @Test("Every action is applicable to at least one kind")
    func everyActionIsUsefulSomewhere() {
        for action in AfterCaptureActions.allCases {
            #expect(
                CaptureKind.allCases.contains { action.applies(to: $0) },
                "\(action.title) applies to nothing"
            )
        }
    }

    @Test("Every action has a title of its own")
    func titles() {
        let titles = Set(AfterCaptureActions.allCases.map(\.title))
        #expect(titles.count == AfterCaptureActions.allCases.count)
    }

    // MARK: - Migration

    /// The old setting is the only statement the user has ever made about this; discarding
    /// it to show them a nicer pane would be rude.
    @Test("Every old default action migrates to an equivalent row", arguments: [
        (DefaultCaptureAction.copyToClipboard, AfterCaptureActions([.overlay, .copy])),
        (.saveToFolder, AfterCaptureActions([.overlay, .save])),
        (.copyAndSave, AfterCaptureActions([.overlay, .copy, .save])),
        (.overlayOnly, AfterCaptureActions([.overlay]))
    ])
    func migration(action: DefaultCaptureAction, expected: AfterCaptureActions) {
        #expect(AfterCaptureMatrix.migrating(action)[.screenshot] == expected)
    }

    /// Recordings were never copied whatever the old setting said, because the old output
    /// path only ever put a still on the clipboard.
    @Test("Migration never starts copying recordings")
    func migrationDoesNotCopyRecordings() {
        for action in DefaultCaptureAction.allCases {
            #expect(!AfterCaptureMatrix.migrating(action)[.recording].contains(.copy))
        }
    }

    @Test("A migrated matrix always shows a card, as the old behaviour did")
    func migrationKeepsTheOverlay() {
        for action in DefaultCaptureAction.allCases {
            #expect(AfterCaptureMatrix.migrating(action)[.screenshot].contains(.overlay))
            #expect(AfterCaptureMatrix.migrating(action)[.recording].contains(.overlay))
        }
    }

    // MARK: - Storage

    private func throwawayDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("A matrix round-trips through the defaults store")
    func roundTrips() {
        let store = throwawayDefaults()
        var matrix = AfterCaptureMatrix()
        matrix[.screenshot] = [.overlay, .copy, .annotate]
        matrix[.recording] = [.save, .openEditor]

        matrix.write(to: store, forKey: "test.afterCapture")
        #expect(AfterCaptureMatrix.read(from: store, forKey: "test.afterCapture") == matrix)
    }

    /// `defaults read` should stay legible: a raw bitmask is already about as opaque as a
    /// preference gets, and wrapping it in an encoded blob would make it un-editable.
    @Test("It is stored as two plain integers, not a blob")
    func storedLegibly() {
        let store = throwawayDefaults()
        AfterCaptureMatrix.standard.write(to: store, forKey: "test.afterCapture")

        #expect(store.object(forKey: "test.afterCapture.screenshot") is Int)
        #expect(store.object(forKey: "test.afterCapture.recording") is Int)
    }

    @Test("Nothing stored reads as nothing, so the default applies")
    func nothingStored() {
        #expect(AfterCaptureMatrix.read(from: throwawayDefaults(), forKey: "test.absent") == nil)
    }

    @Test("A half-written pair is treated as absent rather than as half a matrix")
    func halfWritten() {
        let store = throwawayDefaults()
        store.set(3, forKey: "test.afterCapture.screenshot")
        #expect(AfterCaptureMatrix.read(from: store, forKey: "test.afterCapture") == nil)
    }
}

/// The schema bump that introduced the matrix (docs/04 §9, docs/09 U2.2).
@Suite("After-capture migration")
struct AfterCaptureMigrationTests {
    private func store(defaultAction: String?, schema: Int) -> UserDefaults {
        let suite = UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        store.removePersistentDomain(forName: suite)
        store.set(schema, forKey: SettingKeys.schemaVersion.name)
        if let defaultAction {
            store.set(defaultAction, forKey: SettingKeys.defaultAction.name)
        }
        return store
    }

    /// The behaviour someone chose in an earlier version has to survive the upgrade.
    @Test("An existing preference becomes the equivalent matrix row", arguments: [
        ("copyAndSave", AfterCaptureActions([.overlay, .copy, .save])),
        ("saveToFolder", AfterCaptureActions([.overlay, .save])),
        ("overlayOnly", AfterCaptureActions([.overlay]))
    ])
    func existingPreferenceMigrates(stored: String, expected: AfterCaptureActions) {
        let store = store(defaultAction: stored, schema: 2)
        SettingsMigrator.migrate(store)

        let matrix = AfterCaptureMatrix.read(from: store, forKey: SettingKeys.afterCapture.name)
        #expect(matrix?[.screenshot] == expected)
    }

    @Test("A store with no preference at all gets the default's equivalent")
    func noPreferenceMigrates() {
        let store = store(defaultAction: nil, schema: 2)
        SettingsMigrator.migrate(store)

        let matrix = AfterCaptureMatrix.read(from: store, forKey: SettingKeys.afterCapture.name)
        #expect(matrix?[.screenshot].contains(.copy) == true, "the old default was copy")
    }

    @Test("The migration runs once and does not overwrite a matrix that exists")
    func migrationIsIdempotent() {
        let store = store(defaultAction: "copyAndSave", schema: 2)
        SettingsMigrator.migrate(store)

        var edited = AfterCaptureMatrix()
        edited[.screenshot] = [.overlay]
        edited.write(to: store, forKey: SettingKeys.afterCapture.name)
        store.set(2, forKey: SettingKeys.schemaVersion.name)
        SettingsMigrator.migrate(store)

        let matrix = AfterCaptureMatrix.read(from: store, forKey: SettingKeys.afterCapture.name)
        #expect(matrix?[.screenshot] == [.overlay], "a matrix the user has edited must survive")
    }

    @Test("The schema is stamped forward")
    func schemaIsStamped() {
        let store = store(defaultAction: "copyToClipboard", schema: 2)
        SettingsMigrator.migrate(store)
        #expect(store[SettingKeys.schemaVersion] == SettingsMigrator.currentVersion)
    }

    /// A store from a *newer* Kadr must be left alone: downgrading must not silently
    /// discard preferences written by a later version.
    @Test("A newer store is not touched")
    func newerStoreIsLeftAlone() {
        let store = store(defaultAction: "copyToClipboard", schema: 99)
        SettingsMigrator.migrate(store)
        #expect(AfterCaptureMatrix.read(from: store, forKey: SettingKeys.afterCapture.name) == nil)
    }
}
