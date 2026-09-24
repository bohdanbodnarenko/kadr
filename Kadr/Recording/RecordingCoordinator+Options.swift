import Foundation
import os
import OverlayKit
import RecordingCore
import SettingsKit

/// What the next take records with, from the settings and any one-run overrides.
@MainActor
extension RecordingCoordinator {
    var currentOptions: RecordingOptions {
        let requestedRate = overrides.frameRate ?? settings.recordingFrameRate.rawValue
        return RecordingOptions(
            // An automation may ask for a frame rate the encoder presets do not have; the
            // nearest preset is a better answer than refusing the recording.
            frameRate: RecordingFrameRate.nearest(to: requestedRate),
            codec: settings.recordingCodec == .hevc ? .hevc : .h264,
            capturesSystemAudio: overrides.recordsSystemAudio ?? settings.recordsSystemAudio,
            capturesMicrophone: overrides.recordsMicrophone ?? settings.recordsMicrophone,
            microphoneDeviceID: settings.recordingMicrophoneDeviceID.isEmpty
                ? nil
                : settings.recordingMicrophoneDeviceID,
            showsCursor: showsCursor,
            dynamicRange: settings.recordingDynamicRange,
            recordsMono: settings.recordsMono
        )
    }

    /// Whether the system cursor is baked into the recording.
    ///
    /// Left out only when the user has asked the studio to draw it back, and only when
    /// there is a session to draw it back from. A cursor cannot be added to footage that
    /// never had one and has no sidecar either, so recording without one in that case would
    /// simply lose the pointer (docs/09 U3.1).
    var showsCursor: Bool {
        guard settings.recordingReconstructsCursor, capturesStudioSession else {
            return settings.recordingShowsCursor
        }
        return false
    }
}

@MainActor
extension RecordingCoordinator {
    /// Turns on only the overlays the user asked for, and tells the engine where to get
    /// them (docs/03 §1.8).
    func startOverlays(for target: RecordingTarget, cameraDeviceID: String? = nil) {
        // The webcam belongs to one of the two paths, never both: a studio session records
        // the camera to its own file so the bubble stays editable, and macOS will not hand
        // the same device to two capture sessions. Baking a bubble that can no longer be
        // moved is also the exact decision the studio exists to postpone.
        let bakesWebcam = settings.recordingShowsWebcam && !capturesStudioSession
        let wantsAny = settings.recordingShowsClicks
            || settings.recordingShowsKeystrokes
            || bakesWebcam
        // Nothing is baked into an HDR recording (docs/11 S0.5).
        //
        // HDR moves the stream to `ARGB2101010LEPacked`, and `CGBitmapContext` has no
        // representation for it — not a missing branch, an absent capability: no
        // combination of bits-per-component, alpha and byte order CoreGraphics accepts
        // describes that layout. It used to be described as 8-bit BGRA instead, which
        // *succeeded*, because both are four bytes per pixel, and then reinterpreted
        // 10-bit data as 8888 over every pixel the overlay touched. Two independent
        // switches in the same settings pane.
        //
        // Skipped rather than worked around, because the studio already draws all of this
        // at export time from the telemetry — and does it better, since an overlay that was
        // never baked can still be turned off, moved or restyled afterwards. The user loses
        // nothing but the preview-in-the-file, and gains a recording whose pixels are the
        // ones the display sent.
        guard !currentOptions.recordsHDR else {
            logger.info("HDR recording: overlays are left to the studio rather than baked in")
            if wantsAny, startNotice == nil {
                // Said, not only logged: the user switched these on (docs/17 T-REC-11).
                startNotice = capturesStudioSession
                    ? String(localized: "HDR: overlays are added in the studio, not the file.")
                    : String(localized: "HDR recordings don't include overlays.")
            }
            Task { await engine.setOverlayProvider(nil) }
            return
        }
        guard wantsAny else {
            Task { await engine.setOverlayProvider(nil) }
            return
        }

        var configuration = RecordingOverlaySource.Configuration()
        configuration.showsClicks = settings.recordingShowsClicks
        configuration.showsKeystrokes = settings.recordingShowsKeystrokes
        configuration.keystrokesOnlyWithModifiers = settings.recordingKeystrokesShortcutsOnly
        configuration.keystrokePosition = KeystrokePosition(
            rawValue: settings.recordingKeystrokePosition.rawValue
        ) ?? .bottomCentre
        configuration.keystrokeAppearance = settings.recordingKeystrokeAppearance
        configuration.keystrokeScale = CGFloat(settings.recordingKeystrokeScale)
        configuration.showsWebcam = bakesWebcam
        configuration.webcamDeviceID = cameraDeviceID ?? settings.recordingCameraDeviceID
        configuration.webcamIsCircular = settings.recordingWebcamCircular
        configuration.webcamSizeFraction = CGFloat(settings.recordingWebcamSize)
        configuration.webcamFillsFrame = settings.recordingWebcamFillsFrame
        configuration.webcamCorner = OverlayCornerSlot(
            rawValue: settings.recordingWebcamCorner.rawValue
        ) ?? .bottomTrailing
        configuration.webcamPixelSide = Self.webcamPixelSide(
            recordedPixels: Self.recordedPixelSize(for: target),
            sizeFraction: configuration.webcamSizeFraction,
            fillsFrame: configuration.webcamFillsFrame
        )
        configuration.clickRed = settings.recordingClickRed
        configuration.clickGreen = settings.recordingClickGreen
        configuration.clickBlue = settings.recordingClickBlue
        configuration.clickScale = CGFloat(settings.recordingClickScale)
        configuration.clickFilled = settings.recordingClickFilled
        configuration.pointConverter = Self.pointConverter(for: target)

        overlaySource.start(configuration: configuration)
        let source = overlaySource
        Task { await engine.setOverlayProvider(source) }
    }
}

/// What VoiceOver is told when a take changes state, if anything.
nonisolated enum RecordingAnnouncement {
    static func message(from old: RecordingState, to new: RecordingState) -> String? {
        switch (old, new) {
        case (.starting, .recording): String(localized: "Recording started")
        case (.recording, .paused): String(localized: "Recording paused")
        case (.paused, .recording): String(localized: "Recording resumed")
        case (_, .finishing): String(localized: "Saving recording")
        case (.finishing, .idle): String(localized: "Recording saved")
        case (.recording, .idle), (.paused, .idle): String(localized: "Recording discarded")
        default: nil
        }
    }
}
