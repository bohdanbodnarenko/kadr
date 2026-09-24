import AppKit
import CoreGraphics
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// What the bar shows, as one observable value the panel can update in place.
@MainActor
@Observable
final class RecordingControlBarModel {
    enum Mode: Equatable {
        case picker
        case preRoll
        case live
    }

    var elapsedText = "0:00"
    var isPaused = false
    /// The level meter, observed on its own (PRD §8).
    ///
    /// Not a property of this model: the meter moves ten times a second, and anything that
    /// read a level stored here would re-evaluate the whole transport on every tick. Only
    /// `RecordingLiveAudioMeter` reads `meter.level`, so only it redraws.
    @ObservationIgnored let meter = RecordingAudioMeterModel()
    var microphoneIsSilent = false
    var notice: String?
    var isTransitioning = false
    var picker: RecordSetupModel?
    /// Non-nil once a recording (or its countdown) owns the bar.
    var session: Bool?
    var preRoll: RecordingControlBar.PreRoll?
    var settings: AppSettings?
    var chrome: RecordingControlChrome = .island
    var docksToNotch = false
    var notchVisible = false
    var notchExpanded = false
    var notchMetrics = RecordingNotchMetrics.fallback
    /// The transport has turned into "Discard this recording?" or "Start over?". Shared by
    /// both chromes so the notch stays expanded while it is asking.
    var confirmation: RecordingBarConfirmation?
    /// Stopped, and the file is being finalised: the transport gives way to "Saving…".
    var isSaving = false
    /// The size the bar opens at when it takes over from the All-in-One island, before it
    /// springs to its own width. Nil the rest of the time.
    var entranceSize: CGSize?
    /// The bar's frame inside the panel, reported by SwiftUI. Not observed: nothing
    /// renders from it, and it changes every frame of a morph.
    @ObservationIgnored var barFrameInPanel: CGRect = .zero

    var mode: Mode {
        Self.mode(
            hasPicker: picker != nil,
            hasSession: session != nil,
            hasPreRoll: preRoll != nil && settings != nil
        )
    }

    static func mode(hasPicker: Bool, hasSession: Bool, hasPreRoll: Bool) -> Mode {
        if hasPicker, !hasSession {
            return .picker
        }
        return hasPreRoll ? .preRoll : .live
    }

    /// Hovering expands the notch; so does anything that needs the controls without a
    /// hover — a countdown, the discard confirmation, VoiceOver.
    var notchLayout: RecordingNotchLayout {
        RecordingNotchLayout(
            hardware: notchMetrics,
            isExpanded: notchExpanded || preRoll != nil || confirmation != nil
                || AccessibilityChrome.voiceOverEnabled,
            isVisible: notchVisible
        )
    }

    @ObservationIgnored var stop: () -> Void = {}
    @ObservationIgnored var togglePause: () -> Void = {}
    @ObservationIgnored var cancel: () -> Void = {}
    @ObservationIgnored var restart: () -> Void = {}

    /// Writes only what changed.
    ///
    /// An `@Observable` setter invalidates its readers whether or not the value moved, so
    /// assigning the same clock text again still re-rendered the bar.
    func apply(_ controls: RecordingControls) {
        if elapsedText != controls.elapsedText {
            elapsedText = controls.elapsedText
        }
        if isPaused != controls.isPaused {
            isPaused = controls.isPaused
        }
        meter.set(controls.audioLevel)
        if microphoneIsSilent != controls.microphoneIsSilent {
            microphoneIsSilent = controls.microphoneIsSilent
        }
        if notice != controls.notice {
            notice = controls.notice
        }
        if isTransitioning != controls.isTransitioning {
            isTransitioning = controls.isTransitioning
        }
        if isSaving != controls.isSaving {
            isSaving = controls.isSaving
            if isSaving {
                confirmation = nil
            }
        }
        stop = controls.stop
        togglePause = controls.togglePause
        cancel = controls.cancel
        restart = controls.restart
    }
}

/// A destructive transport action the bar is asking about in place.
///
/// Discard and Start Over both throw the take away, so both ask first (docs/17 T-REC-11).
enum RecordingBarConfirmation: Equatable {
    case discard
    case restart
}

/// The floating bar's level meter, as its own observable (PRD §8).
@MainActor
@Observable
final class RecordingAudioMeterModel {
    private(set) var level: Float = 0

    func set(_ newLevel: Float) {
        guard newLevel != level else { return }
        level = newLevel
    }
}
