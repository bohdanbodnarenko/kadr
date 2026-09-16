import Foundation
import os
import Shared
import StudioSession

/// Autosaving the edit in progress (docs/09 U3.1, docs/11 S2).
///
/// Throttled, not debounced, and written off the main actor. A slider drag calls `change`
/// per pixel of travel, and each call used to JSON-encode the whole edit and write it
/// atomically on the MainActor — a temporary file, a rename and an fsync per tick, while the
/// preview was trying to redraw on the same actor.
///
/// A plain debounce would have been wrong, and the existing tests said so: with one, a
/// session that had just been edited had no draft on disk yet, so it did not look unfinished
/// to the recovery prompt and reopening it found nothing to restore. So:
///
/// - The very first draft this model writes is written in place. It is the file that turns
///   the session into "somebody is in the middle of this", and it is written once.
/// - After that, the first change in a burst is handed to `StudioDraftWriter` immediately,
///   and the ones treading on its heels collapse into a single trailing write.
/// - Every write carries a generation. The writer drops anything older than what it has
///   already written, and anything at or below the *fence* a synchronous flush put up — so a
///   background write that was still queued when the window closed cannot land after the
///   commit and make a cleanly closed session look interrupted again.
@MainActor
extension StudioDocumentModel {
    /// Writes the draft. Failures are logged rather than surfaced.
    ///
    /// A dialog every time an autosave misses would be worse than the miss: the user is in
    /// the middle of something, the work is still on screen, and the next keystroke tries
    /// again. What must not happen silently is losing an *export*, and that reports.
    func saveDraft() {
        draftGeneration += 1
        guard hasWrittenDraft else {
            writeDraftInPlace()
            return
        }
        let now = ContinuousClock.now
        if let last = lastDraftWrite, now - last < Self.draftInterval {
            draftSave?.cancel()
            draftSave = Task { [weak self] in
                try? await Task.sleep(for: Self.draftInterval)
                guard !Task.isCancelled else { return }
                self?.draftSave = nil
                self?.enqueueDraftWrite()
            }
            return
        }
        enqueueDraftWrite()
    }

    /// Writes the draft now, and fences off every queued write that is not newer.
    ///
    /// Synchronous on purpose: it is called right before a commit — on close and before an
    /// export — and both of those are followed by code that assumes the draft on disk is the
    /// edit in memory. When the background writer has already written this generation, only
    /// the fence moves and nothing is written twice.
    func flushDraft() {
        draftSave?.cancel()
        draftSave = nil
        guard draftGeneration > 0 else { return }
        writeDraftInPlace()
    }

    private func enqueueDraftWrite() {
        lastDraftWrite = ContinuousClock.now
        let edit = edit
        let generation = draftGeneration
        let writer = draftWriter
        Task {
            await writer.write(edit, generation: generation)
        }
    }

    private func writeDraftInPlace() {
        lastDraftWrite = ContinuousClock.now
        hasWrittenDraft = true
        draftWriter.writeSynchronously(edit, generation: draftGeneration)
    }
}

/// The serial, latest-wins writer behind the studio's autosave.
///
/// An actor so encoding and writing happen on the cooperative pool, one at a time. The
/// ordering guarantee does not depend on the order tasks reach the actor — they are not
/// promised to arrive in the order they were created — but on generations checked under a
/// lock that the main actor's synchronous flush takes too.
actor StudioDraftWriter {
    private struct Gate: Sendable {
        /// The newest generation on disk.
        var written = 0
        /// Nothing at or below this may be written by the background path any more.
        var fence = 0
    }

    private let document: SessionDocument
    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    private let logger = KadrLog.logger(.app)
    private let signposter = KadrLog.signposter(.app)

    init(document: SessionDocument) {
        self.document = document
    }

    /// Writes `edit` unless something newer already reached the disk or a flush fenced it.
    func write(_ edit: StudioEdit, generation: Int) {
        perform(edit, generation: generation, fencing: false)
    }

    /// The synchronous path, for the main actor's flush. Holds the same lock as the
    /// background path, so at worst it waits for one in-flight write to finish.
    nonisolated func writeSynchronously(_ edit: StudioEdit, generation: Int) {
        perform(edit, generation: generation, fencing: true)
    }

    /// Which generations have been written and fenced, for tests.
    nonisolated var state: (written: Int, fence: Int) {
        gate.withLock { ($0.written, $0.fence) }
    }

    private nonisolated func perform(_ edit: StudioEdit, generation: Int, fencing: Bool) {
        let document = document
        let signpostState = signposter.beginInterval("studio.draft.write")
        defer { signposter.endInterval("studio.draft.write", signpostState) }
        let failure: String? = gate.withLock { gate in
            defer {
                if fencing {
                    gate.fence = max(gate.fence, generation)
                }
            }
            guard generation > gate.written else { return nil }
            guard fencing || generation > gate.fence else { return nil }
            do {
                try document.writeDraft(edit)
                gate.written = generation
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let failure {
            logger.error("Could not autosave the studio edit: \(failure, privacy: .public)")
        }
    }
}
