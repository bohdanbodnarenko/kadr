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
        source.recordingStartedAt = Date()
        source.stop()

        #expect(source.recordingStartedAt != nil)
        #expect(source.overlay(atRecordingTime: 0).clicks.isEmpty)
        #expect(source.overlay(atRecordingTime: 0).webcamFrame == nil)
    }
}
