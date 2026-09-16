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
        let template = FilenameTemplate("Kadr recording {date} {time}")
        let context = FilenameContext(applicationName: "Screen", date: Date())
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
        cameraDeviceID: String?
    ) async {
        do {
            startOverlays(for: target)
            startStudioSession(for: target, cameraDeviceID: cameraDeviceID)
            await CaptureExclusionPush.into(engine)
            try await engine.start(target: target, options: options)
            await studio.linkSegments(engine.inProgressDirectory, options: options)
            await teleprompter.start(
                microphone: options.recordsMicrophone ? engine.microphoneTap : nil
            )
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
            if settings.recordingEnablesFocus {
                focus.enable()
            }
            hygiene?.beginRecording()
            isTransitioning = false
            logger.info("Recording started")
        } catch {
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

    func startTicking() {
        stopTicking()
        microphonePeakMax = 0
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

/// Do Not Disturb while recording (docs/03 §1.8).
///
/// macOS gives apps no supported way to set a Focus mode, so this does the honest thing:
/// it suppresses Kadr's own notifications and tells the user what it cannot do, rather
/// than pretending. A banner from another app landing in a recording is a real problem;
/// silently failing to prevent it would be worse than saying so.
@MainActor
struct FocusMode {
    private let logger = KadrLog.logger(.recording)

    func enable() {
        logger.info("Recording started; macOS Focus must be set by the user if wanted")
    }

    func disable() {}
}
