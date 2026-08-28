import AppKit
import CoreGraphics
import Foundation
import RecordingCore
import Testing
@testable import Kadr

/// The recording overlays (docs/03 §1.8).
///
/// These tests exist for one property above all: nothing here observes the system while
/// Kadr is idle. Keystrokes and the webcam are deliberately left out — a `CGEventTap`
/// prompts for Accessibility and the camera turns on a light — so the click monitor,
/// which needs no permission, stands in for the lifecycle.
@MainActor
@Suite(.serialized)
struct RecordingOverlaySourceTests {
    @Test("Nothing observes the system before a recording starts")
    func idleByDefault() {
        let source = RecordingOverlaySource()
        #expect(source.isObserving == false)
    }

    @Test("Every monitor is gone after stop")
    func stopTearsDownMonitors() {
        let source = RecordingOverlaySource()
        var configuration = RecordingOverlaySource.Configuration()
        configuration.showsClicks = true
        source.start(configuration: configuration)
        #expect(source.isObserving)

        source.stop()
        #expect(source.isObserving == false)
    }

    @Test("Stopping is safe when nothing was started")
    func stopWithoutStart() {
        let source = RecordingOverlaySource()
        source.stop()
        #expect(source.isObserving == false)
    }

    @Test("Starting twice does not leave the first monitor behind")
    func restartReplacesMonitors() {
        let source = RecordingOverlaySource()
        var configuration = RecordingOverlaySource.Configuration()
        configuration.showsClicks = true
        source.start(configuration: configuration)
        source.start(configuration: configuration)
        source.stop()
        #expect(source.isObserving == false)
    }

    @Test("An overlay with nothing turned on draws nothing")
    func emptyOverlayIsEmpty() {
        let source = RecordingOverlaySource()
        source.start(configuration: RecordingOverlaySource.Configuration())
        defer { source.stop() }

        let overlay = source.overlay(atRecordingTime: 1)
        #expect(overlay.clicks.isEmpty)
        #expect(overlay.keystrokes == nil)
        #expect(overlay.webcamFrame == nil)
        #expect(source.isObserving == false)
    }

    @Test("Stop clears the frames it was holding")
    func stopClearsState() {
        let source = RecordingOverlaySource()
        var configuration = RecordingOverlaySource.Configuration()
        configuration.showsClicks = true
        source.start(configuration: configuration)
        source.stop()

        #expect(source.overlay(atRecordingTime: 0).clicks.isEmpty)
        #expect(source.overlay(atRecordingTime: 0).webcamFrame == nil)
    }
}

/// Which clock overlay effects are stamped with (docs/07 M2, docs/09 U0.3).
///
/// The review found two clocks: the engine composites against *recording* time, which
/// stops while paused, and the source stamped events with wall time, which does not.
/// After a pause the two diverge by the length of the pause and halos stop drawing.
@MainActor
@Suite("Overlay clock")
struct RecordingOverlayClockTests {
    private func makeSource() -> RecordingOverlaySource {
        let source = RecordingOverlaySource()
        var configuration = RecordingOverlaySource.Configuration()
        configuration.showsClicks = true
        // The overlay maps screen points through this; identity keeps the test about time.
        configuration.pointConverter = { $0 }
        source.start(configuration: configuration)
        return source
    }

    @Test("A click is stamped with the recording time, not the wall clock")
    func clickUsesRecordingTime() {
        let source = makeSource()
        defer { source.stop() }

        // The engine has composited up to 5 s of recording.
        _ = source.overlay(atRecordingTime: 5)
        source.recordClickForTesting(at: CGPoint(x: 10, y: 10))

        // A frame a moment later must show the halo at the very start of its life.
        let overlay = source.overlay(atRecordingTime: 5.1)
        #expect(overlay.clicks.count == 1)
        #expect((overlay.clicks.first?.progress ?? 1) < 0.5, "the halo should have just begun")
    }

    /// The pause case, stated directly: recording time does not advance while paused, so
    /// a click after the pause still lands where the engine is.
    @Test("A click after a pause still draws")
    func clickAfterPauseStillDraws() {
        let source = makeSource()
        defer { source.stop() }

        _ = source.overlay(atRecordingTime: 3)
        // …the user pauses for a while, and recording time stays put…
        _ = source.overlay(atRecordingTime: 3)
        source.recordClickForTesting(at: CGPoint(x: 1, y: 1))

        let overlay = source.overlay(atRecordingTime: 3.05)
        #expect(overlay.clicks.count == 1, "a wall-clock stamp would sit in the future and never draw")
    }

    @Test("Halos expire on the recording's clock")
    func halosExpire() {
        let source = makeSource()
        defer { source.stop() }

        _ = source.overlay(atRecordingTime: 0)
        source.recordClickForTesting(at: CGPoint(x: 2, y: 2))
        #expect(source.overlay(atRecordingTime: 0.1).clicks.count == 1)
        #expect(source.overlay(atRecordingTime: 30).clicks.isEmpty, "old halos must not accumulate")
    }

    @Test("A new recording starts the clock again")
    func resetClockStartsOver() {
        let source = makeSource()
        defer { source.stop() }

        _ = source.overlay(atRecordingTime: 42)
        source.resetClock()
        source.recordClickForTesting(at: CGPoint(x: 3, y: 3))

        #expect(source.overlay(atRecordingTime: 0.1).clicks.count == 1)
    }
}
