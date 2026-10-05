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
        guard state == .recording, !isTransitioning else { return }
        isTransitioning = true
        studio.pauseCamera()
        studio.pauseTelemetry()
        transportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isTransitioning = false
                transportTask = nil
            }
            do {
                try await engine.pause()
            } catch {
                // Still recording: undo the early camera and telemetry pause, and say so
                // rather than leave a bar that looks paused-pending forever (docs/18 X-5a).
                studio.resumeTelemetry()
                studio.resumeCamera()
                FailurePresenter.report(
                    "Kadr could not pause the recording. It is still recording.",
                    detail: error.localizedDescription,
                    logger: logger
                )
                return
            }
            // Stop or Discard may have landed while the segment closed. Writing `.paused`
            // over their `.finishing` or `.idle` left a phantom paused take that only Stop
            // could clear, and Stop then reported an error (docs/17 T-REC-8).
            guard state == .recording else { return }
            // The script holds where it is: a prompter that keeps scrolling through a
            // pause is one the reader has to scroll back on when they resume.
            teleprompter.pause()
            studio.pauseCamera()
            state = .paused
            pausedAt = Date()
            stopTicking()
        }
    }

    func resume() {
        guard state == .paused, !isTransitioning else { return }
        isTransitioning = true
        studio.resumeTelemetry()
        studio.resumeCamera()
        transportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isTransitioning = false
                transportTask = nil
            }
            do {
                try await engine.resume()
            } catch {
                studio.pauseCamera()
                studio.pauseTelemetry()
                FailurePresenter.report(
                    "Kadr could not resume the recording. It is still paused.",
                    detail: error.localizedDescription,
                    logger: logger
                )
                return
            }
            // Same as pause: a Stop in the meantime owns the state now, and restarting the
            // tick here would leave it running at 10 Hz with nothing recording (rule 2).
            guard state == .paused else { return }
            if let pausedAt {
                // Paused time is time the user chose not to record, so the clock skips it
                // exactly as the file does.
                pausedDuration += Date().timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            state = .recording
            if liveNotice == Self.sleepNotice {
                liveNotice = nil
            }
            teleprompter.resume()
            studio.resumeCamera()
            // The sidecar's clock needs no nudge here. It comes from the engine, which
            // counts composited frames and so has already left the pause out — deriving a
            // second answer from the wall clock would only give the two something to
            // disagree about.
            startTicking()
        }
    }

    /// The seconds of "walking to the Stop button" to drop from the end (docs/03 §1.8).
    ///
    /// Read before the stop tears anything down: the travel is a fact about the recording
    /// that has just ended, and the telemetry recorder stops with it.
    private func travelTail() -> TimeInterval {
        let tail = StopTailPolicy.tail(
            travel: studio.travelToControls,
            content: StopTailPolicy.Content(
                lastInput: studio.lastInputTime,
                lastAudible: lastAudibleTime
            ),
            duration: elapsed
        )
        if tail > 0 {
            logger.info("Trimming \(tail, format: .fixed(precision: 2), privacy: .public)s of travel to Stop")
        }
        return tail
    }

    /// Stops and finalises. `completion` is how `kadr stop-recording` learns the path.
    ///
    /// - Parameter trimmingTravel: whether the last seconds — the pointer's trip to the
    ///   Stop button — come off the end (docs/03 §1.8). True for the controls' own stop
    ///   button; false for a hotkey, automation, or a recording that ended itself, where
    ///   the pointer went nowhere and the last second is as much the recording as any other.
    func stop(trimmingTravel: Bool = false, reportingTo completion: ((CaptureOutcome) -> Void)? = nil) {
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
        isTransitioning = true
        stopTicking()
        stopOverlays()
        stopGeometryObserver()
        teleprompter.stop()
        hygiene?.endRecording()

        let destination = destinationURL()
        let interruption = pendingInterruption
        pendingInterruption = nil
        let tail = trimmingTravel ? travelTail() : 0
        let transport = transportTask
        Task { [weak self] in
            guard let self else { return }
            defer {
                isTransitioning = false
                liveNotice = nil
            }
            // A pause or resume still in flight finishes first, so the engine sees one
            // transition at a time rather than a stop inside a half-closed segment.
            await transport?.value
            do {
                let result = try await engine.stop(
                    savingTo: destination,
                    interruption: interruption,
                    trimmingTail: tail
                )
                await finished(with: result)
            } catch {
                failedToFinish(error)
            }
        }
    }

    /// The take is on disk: hand it on, then assemble the studio session behind it.
    private func finished(with result: RecordingResult) async {
        let exportGIF = wantsGIFExport
        resetAfterStopping()
        logger.info("Recording saved: \(result.fileURL.lastPathComponent, privacy: .private)")

        // The card goes up before the session is assembled. Linking the footage and writing
        // the sidecar takes a moment, and making the user wait for it would put a delay
        // between stopping and seeing the recording that the recording itself does not have.
        report(.file(result.fileURL))
        onFinished?(result, exportGIF)
        if let session = await studio.finish(with: result) {
            onStudioSessionReady?(session, result)
        }
        if result.interruption != nil {
            RecordingFailureNotice.presentInterruption(
                result.interruption ?? "The recording ended unexpectedly."
            )
        }
        finishTerminationIfNeeded()
    }

    private func failedToFinish(_ error: any Error) {
        resetAfterStopping()
        studio.cancel()
        logger.error("Recording failed to finish: \(error.localizedDescription, privacy: .public)")
        report(.failed(error.localizedDescription))
        RecordingFailureNotice.presentStopFailure(error)
        finishTerminationIfNeeded()
    }

    private func resetAfterStopping() {
        state = .idle
        clearTakeState()
    }

    /// Forgets everything about the take that just ended.
    ///
    /// The tick is stopped here as well as where the take stopped: a resume that finished
    /// after the stop could restart it, and a 10 Hz loop running while idle breaks the
    /// agent's zero-CPU budget (rule 2, docs/17 T-REC-8).
    func clearTakeState() {
        stopTicking()
        startedAt = nil
        pausedAt = nil
        pausedDuration = 0
        elapsed = 0
        overrides = .none
        startedByAutomation = false
        wantsGIFExport = false
        microphoneDropped = false
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
        isTransitioning = false
        liveNotice = nil
        stopTicking()
        stopOverlays()
        hygiene?.endRecording()
        studio.cancel()
        stopGeometryObserver()
        teleprompter.stop()
        Task { [weak self] in
            await self?.engine.cancel()
            self?.state = .idle
            self?.clearTakeState()
            self?.report(.cancelled)
            self?.finishTerminationIfNeeded()
        }
    }

    /// Throws this take away and starts the same source again.
    ///
    /// The commonest use is a false start: the first two seconds were reaching for the
    /// mouse, or the wrong window was in front. Split-then-delete in the studio can do
    /// the same job later, but restarting now is one click and does not leave a file
    /// of that false start sitting in History.
    func restart() {
        let target = pendingTarget ?? lastTarget
        guard let target else { return }
        // The same take again, so the same kind of take: a GIF restarts as a GIF.
        let gif = wantsGIFExport
        if cancelCountdown() {
            wantsGIFExport = gif
            startAfterCountdown(target: target)
            return
        }
        guard isRecording else { return }
        Task { [weak self] in
            guard let self else { return }
            await discardWithoutReporting()
            wantsGIFExport = gif
            startAfterCountdown(target: target)
        }
    }

    /// Tears a live recording down without announcing a cancellation.
    ///
    /// Restart uses this so History and the overlay do not briefly show a discarded
    /// take that is about to be replaced. Cancel still reports `.cancelled` so a script
    /// that asked to stop knows the recording did not land.
    private func discardWithoutReporting() async {
        state = .idle
        stopTicking()
        stopOverlays()
        hygiene?.endRecording()
        studio.cancel()
        stopGeometryObserver()
        teleprompter.stop()
        await engine.cancel()
        state = .idle
        clearTakeState()
    }

    /// Reports to whoever asked for this recording, once.
    func report(_ outcome: CaptureOutcome) {
        guard let automationCompletion else { return }
        self.automationCompletion = nil
        automationCompletion(outcome)
    }

    /// Finishes the take before AppKit lets the process exit.
    ///
    /// ⌘Q and a Sparkle relaunch used to kill the writer. A countdown has no footage yet
    /// and is cancelled; a live recording is stopped and saved; a stop already in flight
    /// is waited out.
    func finishForTermination(completion: @escaping () -> Void) {
        if isCountingDown || state == .starting {
            if isCountingDown {
                _ = cancelCountdown()
            } else {
                cancel()
            }
            completion()
            return
        }
        guard state.isActive else {
            completion()
            return
        }
        terminationCompletion = completion
        if isRecording {
            stop()
        }
    }

    private func finishTerminationIfNeeded() {
        let done = terminationCompletion
        terminationCompletion = nil
        done?()
    }
}
