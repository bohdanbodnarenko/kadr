import AppKit
import CaptureCore
import Foundation
import MediaExport
import os
import RecordingCore
import SettingsKit
import Shared

/// Where a recording lands, and the clock the menu bar reads (docs/03 §1.8).
///
/// Split from the coordinator because deciding *what* to record and housekeeping the result
/// change for different reasons — and because the coordinator was over its length budget.
@MainActor
extension RecordingCoordinator {
    /// Where the finished recording lands.
    ///
    /// Counted like every other capture: two recordings stopped inside the same second
    /// used to resolve to the same name, and the second overwrote the first (docs/07 M6).
    func destinationURL() -> URL {
        // The user's own template, as every other capture uses (docs/03 §8.3). `{app}` names
        // what kind of capture this is: the recorded app is not known for a screen or area.
        let template = FilenameTemplate(settings.filenameTemplate)
        let context = FilenameContext(applicationName: "Screen Recording", date: Date())
        let folder = settings.saveFolder

        if let url = try? CaptureFileWriter().availableURL(
            in: folder,
            template: template,
            context: context,
            fileExtension: "mp4"
        ) {
            return url
        }
        return folder.appendingPathComponent(template.expand(context)).appendingPathExtension("mp4")
    }

    func runEngineStart(
        target: RecordingTarget,
        options: RecordingOptions,
        cameraDeviceID: String?,
        generation: Int
    ) async {
        do {
            startOverlays(for: target, cameraDeviceID: cameraDeviceID)
            startStudioSession(for: target, cameraDeviceID: cameraDeviceID)
            await CaptureExclusionPush.into(engine)
            try await engine.start(target: target, options: options)
            await studio.linkSegments(engine.inProgressDirectory, options: options)
            await teleprompter.start(
                microphone: options.recordsMicrophone ? engine.microphoneTap : nil
            )
            // The prompter's panel exists only now, after the stream's filter was fixed;
            // hand the live stream the new list or the script is in the file (T-REC-7).
            await engine.updateExcludedWindowIDs(CaptureExclusionPush.ids)
            // Still ours to claim (docs/11 S0.3).
            //
            // Everything above suspends, and Stop and Cancel both run to completion
            // during those suspensions: they set `.idle`, tear the overlays down and
            // call `studio.cancel()`, which deletes the session directory. Announcing
            // `.recording` afterwards resurrected a recording the user had already
            // stopped — the menu-bar timer counted up against a session that no longer
            // existed on disk. If the state moved out from under us, the engine has
            // already been told to stand down and there is nothing here to claim.
            guard state == .starting else {
                await engine.cancel()
                isTransitioning = false
                logger.info("Recording was stopped while it was still starting")
                return
            }
            state = .recording
            startedAt = Date()
            overlaySource.resetClock()
            pausedDuration = 0
            pausedAt = nil
            startTicking()
            hygiene?.beginRecording()
            isTransitioning = false
            showStartNotice()
            logger.info("Recording started")
        } catch {
            // Only this start's own pieces. A Stop or Cancel during the start has already
            // torn them down, and if another take has claimed the coordinator since, the
            // overlays, studio session and state are its, not ours (docs/17 T-REC-3).
            guard generation == startGeneration, state == .starting else {
                logger.info("A superseded recording start failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            stopOverlays()
            studio.cancel()
            stopGeometryObserver()
            teleprompter.stop()
            hygiene?.endRecording()
            isTransitioning = false
            state = .idle
            // A cancellation is not a capture failure. Feeding it to the permission
            // tracker would count the user's own Escape as evidence that screen
            // recording is broken, and eventually prompt them to fix a working grant.
            guard error as? RecordingError != .cancelledDuringStart else {
                logger.info("Recording was cancelled while it was still starting")
                return
            }
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            permissions.noteCaptureFailure(error)
            presentPermissionRecoveryIfNeeded(error)
            RecordingFailureNotice.presentStartFailure(error)
        }
    }

    /// Says on the bar what the take had to go without — a camera or microphone that was
    /// missing or not allowed — rather than only logging it (docs/17 T-REC-9).
    ///
    /// Cleared after a few seconds by a Task that exists only while a take does.
    private func showStartNotice() {
        guard let notice = startNotice else { return }
        startNotice = nil
        liveNotice = notice
        // The notice is caption text on a bar nobody is reading while they talk; VoiceOver
        // users would otherwise never hear it at all (docs/18 REC-1).
        FeedbackAnnouncement.post(notice)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, liveNotice == notice else { return }
            liveNotice = nil
        }
    }

    func startTicking() {
        stopTicking()
        microphonePeakMax = 0
        lastAudibleTime = nil
        audioMeter = AudioMeter()
        onAudioLevel?(0)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let startedAt else { return }
                let fresh = await engine.audioMeter
                tick(fresh: fresh, startedAt: startedAt)
            }
        }
    }

    /// One tick: the meter every time, everything else only when it visibly changed.
    private func tick(fresh: AudioMeter, startedAt: Date) {
        let before = tickDisplay
        microphonePeakMax = max(microphonePeakMax, fresh.microphone)
        audioMeter = AudioMeter(
            microphone: max(fresh.microphone, audioMeter.microphone * 0.72),
            system: max(fresh.system, audioMeter.system * 0.72)
        )
        elapsed = Date().timeIntervalSince(startedAt) - pausedDuration
        if fresh.peak >= StopTailPolicy.audibleLevel {
            // Remembered for the stop trim: nothing is cut over someone still talking
            // (docs/03 §1.8). The *fresh* peak, not the decayed one the bar draws, or the
            // decay would keep the recording "audible" for a second after silence.
            lastAudibleTime = elapsed
        }
        onAudioLevel?(audioMeter.peak)
        if RecordingTickPolicy.shouldNotify(previous: before, next: tickDisplay) {
            onStateChanged?()
        }
    }

    /// What the tick can change that somebody can see, other than the meter.
    private var tickDisplay: RecordingTickDisplay {
        RecordingTickDisplay(wholeSeconds: Int(elapsed), microphoneIsSilent: microphoneIsSilent)
    }

    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}

/// The part of a recording tick a person can see, apart from the level meter.
///
/// The menu-bar clock is `m:ss`, so a tenth of a second is invisible; the silent-mic notice
/// flips at most a couple of times a take. Everything else the tick touches is the meter,
/// which has its own channel.
nonisolated struct RecordingTickDisplay: Equatable, Sendable {
    var wholeSeconds: Int
    var microphoneIsSilent: Bool
}

/// Decides when a recording tick is worth telling the menu bar about (PRD §8).
///
/// The tick runs at 10 Hz for the meter. Each notification rebuilt the status-item icon and
/// rewrote the floating bar, so notifying on every tick was ten icon rebuilds a second for
/// a clock that changes once.
nonisolated enum RecordingTickPolicy {
    /// How long a take must run before a quiet microphone counts as silent, rather than as
    /// somebody who has not started talking yet.
    static let silenceGraceSeconds: TimeInterval = 2

    static func shouldNotify(previous: RecordingTickDisplay, next: RecordingTickDisplay) -> Bool {
        previous != next
    }

    static func microphoneIsSilent(recordsMicrophone: Bool, elapsed: TimeInterval, peak: Float) -> Bool {
        recordsMicrophone && elapsed > silenceGraceSeconds && peak < AudioMeter.silence
    }
}
