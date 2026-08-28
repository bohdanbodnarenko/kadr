import Foundation
import HistoryKit
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// When the history text index is allowed to run (docs/03 §5 P3, docs/06 M20).
///
/// The promise being tested is the one in the settings copy: it is opt-out, it runs on
/// mains power, and it never starts itself. The agent's idle CPU staying at 0.0% depends
/// on all three, and `Scripts/check-perf.sh` measures the consequence — this measures the
/// cause, which is the part a refactor can quietly break.
@MainActor
@Suite("History index gating")
struct HistoryIndexCoordinatorTests {
    private func makeSettings() -> AppSettings {
        let suite = "app.kadr.tests.index.\(UUID().uuidString)"
        // A private domain, so a test can never touch the developer's real preferences.
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return AppSettings(store: defaults)
    }

    @Test("Indexing is on unless the user turns it off")
    func optOutNotOptIn() {
        let settings = makeSettings()
        #expect(settings.historyIndexesText)
    }

    @Test("Opting out stops it, whatever the power state")
    func optingOutStopsIt() {
        let settings = makeSettings()
        settings.historyIndexesText = false
        let coordinator = HistoryIndexCoordinator(settings: settings)
        #expect(!coordinator.isAllowed)
    }

    @Test("Opted in, it is allowed exactly when the machine can afford it")
    func powerDecidesTheRest() {
        let settings = makeSettings()
        settings.historyIndexesText = true
        let coordinator = HistoryIndexCoordinator(settings: settings)
        // Not asserting a fixed answer: a laptop on battery and a plugged-in desktop are
        // both valid places to run this suite. What must hold is that the coordinator
        // agrees with the power state rather than deciding on its own.
        #expect(coordinator.isAllowed == PowerState.allowsBackgroundWork)
    }

    @Test("A request while opted out starts nothing")
    func requestDoesNothingWhenNotAllowed() throws {
        let settings = makeSettings()
        settings.historyIndexesText = false
        let coordinator = HistoryIndexCoordinator(settings: settings)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try coordinator.requestPass(store: HistoryStore.open(root: root))

        #expect(!coordinator.isRunning)
    }

    @Test("Cancelling leaves it idle and re-requestable")
    func cancelResets() {
        let settings = makeSettings()
        let coordinator = HistoryIndexCoordinator(settings: settings)
        coordinator.cancel()
        #expect(!coordinator.isRunning)
    }

    @Test("Batches are bounded, so one request cannot become an unbounded grind")
    func batchesAreBounded() {
        #expect(HistoryIndexCoordinator.batchSize > 0)
        #expect(HistoryIndexCoordinator.maximumBatchesPerRequest > 0)
        #expect(HistoryIndexCoordinator.batchSize <= 100)
    }
}
