import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import os
import RecordingCore
import Shared

/// Feeds the recording pipeline its click halos, keystrokes and webcam picture
/// (docs/03 §1.8, docs/04 §4.3).
///
/// Everything here is created when a recording starts and destroyed when it stops. That
/// is a hard rule, not a tidiness preference: a global event monitor and a `CGEventTap`
/// are exactly the machinery a screenshot tool should not be running while it sits idle
/// in the menu bar, and the Accessibility permission the tap needs is asked for at the
/// moment it is used, never at launch (docs/04 §3.2).
///
/// The pipeline reads this once per frame from a background context, so reads take a lock
/// and do no work beyond copying a small snapshot.
final class RecordingOverlaySource: RecordingOverlayProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let logger = KadrLog.logger(.recording)

    /// How long a click halo takes to fade.
    private static let pulseDuration: TimeInterval = 0.5
    /// How long a keystroke stays on screen after the last key.
    private static let keystrokeLinger: TimeInterval = 1.6

    struct Configuration: Sendable {
        var showsClicks = false
        var showsKeystrokes = false
        var keystrokesOnlyWithModifiers = true
        var keystrokePosition: KeystrokePosition = .bottomCentre
        var showsWebcam = false
        var webcamIsCircular = true
        /// Maps a screen point into the recorded area's own coordinates.
        /// Screen space in, recorded pixels out — typed, for the reason C1 records
        /// (docs/11 S0.1).
        var pointConverter: @Sendable (ScreenPoint) -> PixelPoint? = { PixelPoint(x: $0.x, y: $0.y) }
    }

    /// A click as it was observed, before it is turned into something to draw.
    private struct RecordedClick {
        /// AppKit's global screen space, origin bottom-left — `NSEvent.mouseLocation`.
        /// Named rather than a bare `CGPoint`, which is the whole of C1 (docs/11 S0.1).
        let position: ScreenPoint
        let time: TimeInterval
        let isRight: Bool
    }

    private var configuration = Configuration()
    private var clicks: [RecordedClick] = []
    private var keystrokes: String?
    private var keystrokeTime: TimeInterval = 0
    private var webcamFrame: CGImage?

    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var webcam: WebcamCapture?

    // MARK: - Lifecycle

    /// Starts only what the configuration asks for.
    @MainActor
    func start(configuration: Configuration) {
        stop()
        lock.withLock { self.configuration = configuration }

        if configuration.showsClicks {
            startClickMonitor()
        }
        if configuration.showsKeystrokes {
            startKeystrokeMonitor()
        }
        if configuration.showsWebcam {
            let webcam = WebcamCapture { [weak self] image in
                self?.lock.withLock { self?.webcamFrame = image }
            }
            webcam.start()
            self.webcam = webcam
        }
    }

    /// Tears everything down. Safe to call when nothing was started.
    @MainActor
    func stop() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            self.eventTap = nil
            runLoopSource = nil
        }
        webcam?.stop()
        webcam = nil

        lock.withLock {
            clicks = []
            keystrokes = nil
            webcamFrame = nil
        }
    }

    /// Whether anything is still observing the system.
    ///
    /// The rule this exists to protect: a screenshot tool has no business running an event
    /// tap, a global monitor or the camera while it is idle in the menu bar. A test asserts
    /// this is `false` after `stop()`.
    var isObserving: Bool {
        mouseMonitor != nil || keyMonitor != nil || eventTap != nil || webcam != nil
    }

    // MARK: - RecordingOverlayProviding

    func overlay(atRecordingTime seconds: TimeInterval) -> RecordingOverlay {
        lock.withLock {
            // The engine's clock is the clock: remember it so events arriving between
            // frames are stamped in the same time base (docs/07 M2).
            recordingTime = seconds

            // Drop halos that have finished rather than accumulating them.
            clicks.removeAll { seconds - $0.time > Self.pulseDuration }

            let pulses = clicks.compactMap { click -> ClickPulse? in
                guard let point = configuration.pointConverter(click.position)?.cgPoint else { return nil }
                let age = seconds - click.time
                guard age >= 0 else { return nil }
                return ClickPulse(
                    position: point,
                    progress: age / Self.pulseDuration,
                    isRightClick: click.isRight
                )
            }

            let text = (seconds - keystrokeTime) < Self.keystrokeLinger ? keystrokes : nil

            return RecordingOverlay(
                clicks: pulses,
                keystrokes: text,
                keystrokePosition: configuration.keystrokePosition,
                webcamFrame: webcamFrame,
                webcamIsCircular: configuration.webcamIsCircular
            )
        }
    }

    /// Where the recording is now, in the file's own time.
    ///
    /// This is the *engine's* clock, learned from the frames it asks us to draw into, and
    /// it is the only clock in here. Stamping events with wall time instead is what made
    /// halos and keystroke pills drift after a pause: the engine composites against
    /// recording time, which stops while paused, so a wall-clock stamp taken after a
    /// ten-second pause lands ten seconds in the future and never draws (docs/07 M2).
    private var recordingTime: TimeInterval = 0

    /// Resets the clock for a new recording.
    func resetClock() {
        lock.withLock { recordingTime = 0 }
    }

    /// The current recording time. Callers already hold the lock.
    private func elapsedLocked() -> TimeInterval {
        recordingTime
    }

    // MARK: - Clicks

    #if DEBUG
        /// Records a click as if the monitor had seen one.
        ///
        /// A test seam: the real path is a global `NSEvent` monitor, which needs a running
        /// event loop and a user. The thing worth testing is which *clock* the click is
        /// stamped with (docs/07 M2), and that is all this bypasses.
        func recordClickForTesting(at position: ScreenPoint, isRight: Bool = false) {
            lock.withLock {
                clicks.append(RecordedClick(position: position, time: elapsedLocked(), isRight: isRight))
            }
        }
    #endif

    @MainActor
    private func startClickMonitor() {
        // A global monitor observes without intercepting, and needs no permission — it is
        // the right tool for "draw a halo where they clicked".
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            let isRight = event.type == .rightMouseDown
            let location = NSEvent.mouseLocation
            lock.withLock {
                clicks.append(RecordedClick(
                    position: ScreenPoint(x: location.x, y: location.y),
                    time: elapsedLocked(),
                    isRight: isRight
                ))
                // A stuck monitor must not grow this without bound.
                if clicks.count > 32 {
                    clicks.removeFirst(clicks.count - 32)
                }
            }
        }
    }

    // MARK: - Keystrokes

    /// Starts the keystroke overlay, asking for Accessibility only now (docs/04 §3.2).
    ///
    /// A `CGEventTap` is the only way to see keys pressed in other apps, and it is a
    /// serious permission. It is requested at the moment the feature is switched on, runs
    /// only while recording, and is torn down on stop.
    @MainActor
    private func startKeystrokeMonitor() {
        // The prompt key is a global the SDK exposes as a mutable var; naming it as a
        // string avoids the concurrency complaint without changing what is asked for.
        let promptOption = "AXTrustedCheckOptionPrompt" as CFString
        guard AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary) else {
            logger.info("Keystroke overlay needs Accessibility permission; skipping it this time")
            return
        }

        let callback: CGEventTapCallBack = { _, _, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let source = Unmanaged<RecordingOverlaySource>.fromOpaque(userInfo).takeUnretainedValue()
            source.record(event)
            // Listen-only: the event is passed straight through untouched.
            return Unmanaged.passUnretained(event)
        }

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Listen only. The tap can see keys but can never swallow or alter one.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            logger.error("Could not create the keystroke event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    /// Formats one key press for the overlay.
    private func record(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let flags = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        let onlyWithModifiers = lock.withLock { configuration.keystrokesOnlyWithModifiers }
        let hasCommandish = !flags.isDisjoint(with: [.command, .control, .option])
        // Showing every keystroke means showing whatever the user types into a password
        // field, so the default is shortcuts only.
        guard !onlyWithModifiers || hasCommandish else { return }

        var text = ""
        if flags.contains(.control) {
            text += "⌃"
        }
        if flags.contains(.option) {
            text += "⌥"
        }
        if flags.contains(.shift) {
            text += "⇧"
        }
        if flags.contains(.command) {
            text += "⌘"
        }
        text += (nsEvent.charactersIgnoringModifiers ?? "").uppercased()

        guard !text.isEmpty else { return }
        lock.withLock {
            keystrokes = text
            keystrokeTime = elapsedLocked()
        }
    }
}

/// The webcam picture-in-picture source (docs/03 §1.8).
///
/// Started with the recording and stopped with it, so the camera light is on exactly when
/// the user is being recorded and at no other time.
private final class WebcamCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.kadr.recording.webcam")
    private let onFrame: @Sendable (CGImage?) -> Void
    private let logger = KadrLog.logger(.recording)

    init(onFrame: @escaping @Sendable (CGImage?) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func start() {
        session.sessionPreset = .medium
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            logger.info("No camera available for the recording overlay")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        // `startRunning` blocks, so it must not run on the caller's thread; the session is
        // driven only from this one serial queue, which is what makes that safe.
        run { $0.startRunning() }
    }

    func stop() {
        run { $0.stopRunning() }
        onFrame(nil)
    }

    /// Runs a session operation on the capture queue.
    ///
    /// `AVCaptureSession` carries no `Sendable` conformance, so it crosses in a documented
    /// box (docs/04 §8). The invariant: this class is its only owner and every touch goes
    /// through here.
    private func run(_ operation: @escaping @Sendable (AVCaptureSession) -> Void) {
        let boxed = SessionBox(session)
        queue.async {
            operation(boxed.session)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let cgImage = Self.cgImage(from: pixelBuffer) else { return }
        onFrame(cgImage)
    }

    /// BGRA bytes to a `CGImage` without CoreImage, so the agent does not link it
    /// (docs/10 R2.1).
    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }
}

/// Carries the capture session onto its own queue. Not `Sendable` in the SDK, driven from
/// exactly one serial queue here (docs/04 §8).
private nonisolated struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession

    init(_ session: AVCaptureSession) {
        self.session = session
    }
}
