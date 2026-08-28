import Foundation
import HistoryKit
import os
import SettingsKit
import Shared

/// Runs the history text index (docs/03 §5 P3, docs/06 M20).
///
/// The split is deliberate: the helper does the recognition, because that is the part
/// that loads Vision's models (docs/04 §1); the library's reads and writes stay here,
/// because `HistoryStore` is the agent's and is its only writer (docs/04 §9). Sending
/// the work rather than the database also keeps the helper from linking one.
///
/// This type owns the promise around it, which is the part a user cares about:
///
/// - **Never on a timer.** A pass is requested only when something already woke the agent
///   up — a capture landed, or the History window opened. The agent's idle path is
///   untouched, which is what "zero agent idle cost" in docs/03 §5 means and what the M10
///   harness measures.
/// - **Mains power only,** and never in Low Power Mode.
/// - **Opt-out,** and turning it off wipes what was learned.
/// - **Batched,** so a large backlog is interruptible rather than a single long stall.
///
/// When the backlog is done the connection is dropped and the helper exits, taking
/// Vision's models with it (docs/04 §7 rule 4).
@MainActor
@Observable
final class HistoryIndexCoordinator {
    private let settings: AppSettings
    @ObservationIgnored private let vision: VisionClient
    @ObservationIgnored private let logger = KadrLog.logger(.history)
    @ObservationIgnored private var task: Task<Void, Never>?

    private(set) var isRunning = false
    /// Captures still waiting to be read, for the hint under the search field.
    private(set) var remaining = 0

    /// Captures per XPC round trip. Small enough that stopping is quick, large enough
    /// that the helper's model-loading cost is amortised over several images.
    static let batchSize = 20

    /// Passes per request. A backlog larger than this waits for the next thing that wakes
    /// the agent up rather than being ground through in one sitting.
    static let maximumBatchesPerRequest = 25

    init(settings: AppSettings, vision: VisionClient = VisionClient()) {
        self.settings = settings
        self.vision = vision
    }

    /// Whether a pass is allowed right now.
    var isAllowed: Bool {
        settings.historyIndexesText && PowerState.allowsBackgroundWork
    }

    /// Asks for a pass. Does nothing when it is not allowed, or one is already running.
    func requestPass(store: HistoryStore) {
        guard isAllowed, task == nil else { return }

        isRunning = true
        task = Task { [weak self] in
            await self?.run(store: store)
        }
    }

    /// Stops after the batch in flight. Used when the user opts out mid-pass.
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func run(store: HistoryStore) async {
        defer {
            task = nil
            isRunning = false
            // Let go so the helper can start its 30-second countdown (docs/04 §1).
            vision.disconnect()
        }

        for _ in 0 ..< Self.maximumBatchesPerRequest {
            guard !Task.isCancelled, isAllowed else { return }
            do {
                let candidates = try await store.indexCandidates(limit: Self.batchSize)
                guard !candidates.isEmpty else {
                    remaining = 0
                    return
                }

                let response = try await vision.indexHistory(HistoryIndexRequest(
                    items: candidates.map { HistoryIndexItem(id: $0.id, path: $0.fileURL.path) }
                ))
                guard !response.isEmpty else { return }

                // The app name is indexed alongside the text, so "that Xcode screenshot"
                // finds one. It comes from the record, not from the helper.
                let applicationNames = Dictionary(
                    candidates.compactMap { candidate in
                        candidate.applicationName.map { (candidate.id, $0) }
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                for result in response.results {
                    try await store.index(
                        id: result.id,
                        text: result.text,
                        applicationName: applicationNames[result.id]
                    )
                }
                remaining = try await store.unindexedCount()
                if remaining == 0 {
                    return
                }
            } catch {
                // A helper that could not run is not worth interrupting anyone over: the
                // library still browses, and the next capture asks again.
                logger.error("History indexing failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        logger.info("History indexing paused with \(self.remaining, privacy: .public) left")
    }
}
