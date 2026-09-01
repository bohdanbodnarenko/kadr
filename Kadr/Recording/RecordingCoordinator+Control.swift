import AppKit
import os
import RecordingCore
import Shared

/// Pausing, resuming, stopping and cancelling a recording in progress (docs/03 §1.8).
///
/// Split from the coordinator on file length, but it reads as a unit for the same reason the
/// engine's lifecycle does: the defects docs/11 found here were races *between* these
/// methods — Stop arriving while Start was still suspended, Cancel deleting a session a
/// half-built recording was about to claim — rather than faults inside any one of them.
@MainActor
extension RecordingCoordinator {
    // MARK: - Controlling

    func pause() {
        guard state == .recording else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.pause()
            } catch {
                logger.error("Could not pause: \(error.localizedDescription, privacy: .public)")
                return
            }
            // The script holds where it is: a prompter that keeps scrolling through a
            // pause is one the reader has to scroll back on when they resume.
            teleprompter.pause()
            state = .paused
            pausedAt = Date()
            stopTicking()
        }
    }

    func resume() {
        guard state == .paused else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.resume()
            } catch {
                logger.error("Could not resume: \(error.localizedDescription, privacy: .public)")
                return
            }
            if let pausedAt {
                // Paused time is time the user chose not to record, so the clock skips it
                // exactly as the file does.
                pausedDuration += Date().timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            state = .recording
            teleprompter.resume()
            // The sidecar's clock needs no nudge here. It comes from the engine, which
            // counts composited frames and so has already left the pause out — deriving a
            // second answer from the wall clock would only give the two something to
            // disagree about.
            startTicking()
        }
    }

    /// Stops and finalises. `completion` is how `kadr stop-recording` learns the path.
    func stop(reportingTo completion: ((CaptureOutcome) -> Void)? = nil) {
        guard isRecording else {
            completion?(.failed("Nothing is recording."))
            return
        }
        // Stopped before the stream came up. There is no footage to finalise, so this is a
        // cancellation — finalising would ask the engine to stop something it never started
        // and report "recording failed to finish" for a recording that never began.
        guard state != .starting else {
            cancel()
            completion?(.cancelled)
            return
        }
        automationCompletion = completion
        state = .finishing
        stopTicking()
        focus.disable()
        stopOverlays()
        stopGeometryObserver()
        teleprompter.stop()
        hygiene?.endRecording()

        let destination = destinationURL()
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.stop(savingTo: destination)
                state = .idle
                elapsed = 0
                overrides = .none
                startedByAutomation = false
                logger.info("Recording saved: \(result.fileURL.lastPathComponent, privacy: .public)")

                // The card goes up before the session is assembled. Linking the footage and
                // writing the sidecar takes a moment, and making the user wait for it would
                // put a delay between stopping and seeing the recording that the recording
                // itself does not have.
                report(.file(result.fileURL))
                onFinished?(result)
                if let session = await studio.finish(with: result) {
                    onStudioSessionReady?(session, result)
                }
            } catch {
                state = .idle
                elapsed = 0
                overrides = .none
                startedByAutomation = false
                studio.cancel()
                logger.error("Recording failed to finish: \(error.localizedDescription, privacy: .public)")
                report(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        // A countdown that has not started recording yet has no engine, no session and no
        // footage — only a promise to begin. Cancelling that is the whole job, and falling
        // through would ask the engine to tear down a recording it never started.
        if cancelCountdown() {
            return
        }
        guard isRecording else { return }
        state = .idle
        stopTicking()
        focus.disable()
        stopOverlays()
        hygiene?.endRecording()
        studio.cancel()
        stopGeometryObserver()
        teleprompter.stop()
        Task { [weak self] in
            await self?.engine.cancel()
            self?.state = .idle
            self?.elapsed = 0
            self?.overrides = .none
            self?.startedByAutomation = false
            self?.report(.cancelled)
        }
    }

    /// Reports to whoever asked for this recording, once.
    private func report(_ outcome: CaptureOutcome) {
        guard let automationCompletion else { return }
        self.automationCompletion = nil
        automationCompletion(outcome)
    }
}
