import AppKit
import CoreGraphics
import Foundation
import os
import Shared
import StudioCore

/// Watches the pointer while a recording runs (docs/09 U3.1).
///
/// The studio's whole approach rests on this: the screen is recorded *without* a cursor,
/// and the cursor is drawn back afterwards from what was captured here. That is what makes
/// smooth zooms possible — a pointer baked into the pixels cannot be moved, smoothed, or
/// scaled with a camera, so a zoomed-in export would show a giant blurry arrow.
///
/// Three ways of watching, in order of quality, because each fails independently and
/// quietly:
///
/// 1. A **listen-only `CGEvent` tap** sees every movement and every press. It needs
///    Accessibility, and macOS disables a tap whose callback runs long — so the callback
///    does nothing but append to an array.
/// 2. **AppKit global monitors** need no permission and still see presses, but report
///    movement only over applications that publish it.
/// 3. A **sampler** reads the pointer's position on a schedule. Coarse, blind to clicks,
///    and never nothing — which is the point of having a floor.
///
/// The tap is listen-only in the strict sense: `.listenOnly`, never `.defaultTap`. Kadr
/// must not be able to modify or swallow another app's input, and a tap that could is a
/// tap somebody has to trust rather than verify.
@MainActor
final class PointerTelemetryRecorder {
    private let logger = KadrLog.logger(.recording)

    private var pointer: [PointerSample] = []
    private var clicks: [ClickEvent] = []
    private var keystrokes: [KeystrokeEvent] = []
    private var cursors: [CursorImage] = []
    /// Cursor artwork already captured, keyed by its bytes, so a session holds one copy of
    /// each cursor rather than one per sample.
    private var cursorIndices: [Data: Int] = [:]

    private var source: TelemetrySource = .sampler
    private var isRecording = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitors: [Any] = []
    private var samplerTask: Task<Void, Never>?

    /// Where the recording is now, in its own time. Set by the engine as it composites, so
    /// the sidecar and the footage share one clock — the fix docs/07 M2 made for the live
    /// overlay, applied from the start here.
    private var recordingTime: TimeInterval = 0
    /// Maps a screen point into the recorded area's pixels.
    private var pointConverter: @Sendable (CGPoint) -> CGPoint? = { $0 }

    var isActive: Bool {
        isRecording
    }

    // MARK: - Lifecycle

    /// Starts watching. Nothing is installed until this is called, and everything is torn
    /// down by `stop` — an idle agent has no tap, no monitors and no timer.
    func start(pointConverter: @escaping @Sendable (CGPoint) -> CGPoint?) {
        guard !isRecording else { return }
        self.pointConverter = pointConverter
        pointer = []
        clicks = []
        keystrokes = []
        cursors = []
        cursorIndices = [:]
        cursorFingerprints = [:]
        lastCursorIndex = nil
        lastCursorCheck = -.infinity
        recordingTime = 0
        isRecording = true

        let availability = TelemetryPolicy.Availability(
            hasEventTap: startEventTap(),
            hasAppKitMonitors: startMonitors()
        )
        source = TelemetryPolicy.source(for: availability)
        if source == .sampler {
            startSampler()
        }
        logger.info("Pointer telemetry: \(self.source.rawValue, privacy: .public)")
    }

    /// Stops watching and hands over what was captured.
    func stop() -> InputTelemetry {
        guard isRecording else { return InputTelemetry() }
        isRecording = false

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        samplerTask?.cancel()
        samplerTask = nil

        return InputTelemetry(
            pointer: pointer,
            clicks: clicks,
            keystrokes: keystrokes,
            cursors: cursors,
            source: source
        )
    }

    /// Tells the recorder where the recording is, so events are stamped in the same clock
    /// the frames are.
    func advance(to time: TimeInterval) {
        recordingTime = time
    }

    // MARK: - Recording events

    private func recordPointer(at screenPoint: CGPoint) {
        guard isRecording, let position = pointConverter(screenPoint) else { return }
        guard TelemetryPolicy.shouldRecord(position, at: recordingTime, lastSample: pointer.last) else {
            return
        }
        pointer.append(PointerSample(
            time: recordingTime,
            position: position,
            cursorIndex: captureCurrentCursor()
        ))
    }

    private func recordClick(at screenPoint: CGPoint, button: ClickEvent.Button, isDown: Bool) {
        guard isRecording, let position = pointConverter(screenPoint) else { return }
        clicks.append(ClickEvent(
            time: recordingTime,
            position: position,
            button: button,
            isDown: isDown
        ))
    }

    // MARK: - Seams

    /// Drives one pointer event, for a test that has no event tap.
    ///
    /// The tap needs an accessibility grant and a real pointer; the *clock* needs neither,
    /// and the clock is what was broken. Declaring the whole of telemetry untestable is how
    /// a frozen timestamp shipped through a suite that passed.
    func recordPointerForTesting(at screenPoint: CGPoint) {
        recordPointer(at: screenPoint)
    }

    func recordClickForTesting(at screenPoint: CGPoint) {
        recordClick(at: screenPoint, button: .left, isDown: true)
    }

    private func recordKeystroke(characters: String?, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        // The privacy rule lives in `TelemetryPolicy` and returns nil for plain typing, so
        // there is nothing here to get wrong or to make configurable.
        guard let caption = TelemetryPolicy.caption(
            characters: characters,
            specialKey: Self.specialKey(for: keyCode),
            modifiers: Self.modifiers(from: flags)
        ) else {
            return
        }
        keystrokes.append(KeystrokeEvent(time: recordingTime, caption: caption))
    }

    /// Cheap evidence that this is a cursor already seen (docs/10 R1.3).
    ///
    /// Size and hotspot, and deliberately not the image's object identity: measured,
    /// `NSCursor.currentSystem` hands back a fresh `NSImage` on every call — five hundred
    /// calls produced five hundred distinct identities — so an identity key can never hit.
    ///
    /// Two different cursors *could* share a size and a hotspot, which is why this only
    /// avoids the re-encode. What gets stored is still decided by comparing the bytes.
    private struct CursorFingerprint: Hashable {
        let width: CGFloat
        let height: CGFloat
        let hotspotX: CGFloat
        let hotspotY: CGFloat

        init(_ cursor: NSCursor) {
            width = cursor.image.size.width
            height = cursor.image.size.height
            hotspotX = cursor.hotSpot.x
            hotspotY = cursor.hotSpot.y
        }
    }

    private var cursorFingerprints: [CursorFingerprint: Int] = [:]
    private var lastCursorIndex: Int?
    private var lastCursorCheck: TimeInterval = -.infinity

    /// How often the cursor is actually looked up.
    ///
    /// `NSCursor.currentSystem` costs about 283µs a call — measured — because it asks the
    /// window server. At sixty samples a second that is 17ms of every second spent finding
    /// out that the pointer is still an arrow, on the main actor, inside the event-tap path
    /// macOS disables if it runs long.
    ///
    /// A quarter of a second is the trade: a cursor that changes shape is drawn with its
    /// old artwork for up to fifteen frames afterwards. The *position* is unaffected —
    /// that comes from the event stream and stays continuous — so what lags is which
    /// picture is drawn, which is the least noticeable thing about a reconstructed cursor
    /// and the only one that costs a window-server round trip.
    private static let cursorCheckInterval: TimeInterval = 0.25

    /// Records the cursor's current artwork, if it is one not seen before.
    ///
    /// Deduplicated by bytes: a recording uses a handful of cursors and touches them
    /// thousands of times, and a session that stored one PNG per sample would be larger
    /// than its own footage.
    ///
    /// The bytes are only *reached for* on a genuine miss. This runs on every pointer
    /// sample — sixty times a second, on the main actor, inside the event-tap path macOS
    /// disables if it runs long — and it used to TIFF-encode, bitmap-decode, PNG-encode and
    /// then hash the whole `Data` every single time, for a cursor that changes perhaps
    /// twenty times in a session (docs/10 R1.3).
    private func captureCurrentCursor() -> Int? {
        guard recordingTime - lastCursorCheck >= Self.cursorCheckInterval else {
            return lastCursorIndex
        }
        lastCursorCheck = recordingTime

        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let fingerprint = CursorFingerprint(cursor)
        if let existing = cursorFingerprints[fingerprint] {
            lastCursorIndex = existing
            return existing
        }

        guard let tiff = cursor.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        // Two fingerprints can still describe the same picture — a cursor rebuilt after a
        // display change is a new object with the same artwork — so the byte comparison
        // stays as the authority on what gets stored.
        if let existing = cursorIndices[png] {
            cursorFingerprints[fingerprint] = existing
            lastCursorIndex = existing
            return existing
        }

        let index = cursors.count
        cursors.append(CursorImage(
            pngData: png,
            hotspot: cursor.hotSpot,
            size: cursor.image.size
        ))
        cursorIndices[png] = index
        cursorFingerprints[fingerprint] = index
        lastCursorIndex = index
        return index
    }

    // MARK: - The three sources

    /// A listen-only tap. Returns whether it could be created.
    private func startEventTap() -> Bool {
        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<PointerTelemetryRecorder>.fromOpaque(context).takeUnretainedValue()
            let location = event.location
            // Straight back out: macOS disables a tap whose callback runs long, and the
            // work belongs on the main actor anyway.
            MainActor.assumeIsolated {
                recorder.handleTapEvent(type: type, at: location)
            }
            // Unmodified, always. A listen-only tap that returned anything else would be
            // editing another app's input.
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.info("No event tap; falling back to monitors")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    private func handleTapEvent(type: CGEventType, at location: CGPoint) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            recordPointer(at: location)
        case .leftMouseDown:
            recordClick(at: location, button: .left, isDown: true)
        case .leftMouseUp:
            recordClick(at: location, button: .left, isDown: false)
        case .rightMouseDown:
            recordClick(at: location, button: .right, isDown: true)
        case .rightMouseUp:
            recordClick(at: location, button: .right, isDown: false)
        default:
            break
        }
    }

    /// AppKit monitors, which need no permission. Returns whether they were installed.
    private func startMonitors() -> Bool {
        let mouse: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp
        ]
        // The event itself is not `Sendable`, so what crosses into the isolated call is
        // the handful of values read from it — which is all the recorder wants anyway.
        let mouseHandler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                self?.handleMonitorEvent(type: type, at: location)
            }
        }
        guard let mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouse,
            handler: mouseHandler
        ) else {
            return false
        }
        monitors.append(mouseMonitor)

        // Keystrokes need Accessibility too; without it this simply returns nil and the
        // sidecar has no captions, which is a smaller loss than no telemetry at all.
        let keyHandler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let characters = event.charactersIgnoringModifiers
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                self?.recordKeystroke(characters: characters, keyCode: keyCode, flags: flags)
            }
        }
        if let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: keyHandler) {
            monitors.append(keyMonitor)
        }
        return true
    }

    private func handleMonitorEvent(type: NSEvent.EventType, at location: CGPoint) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            recordPointer(at: location)
        case .leftMouseDown:
            recordClick(at: location, button: .left, isDown: true)
        case .leftMouseUp:
            recordClick(at: location, button: .left, isDown: false)
        case .rightMouseDown:
            recordClick(at: location, button: .right, isDown: true)
        case .rightMouseUp:
            recordClick(at: location, button: .right, isDown: false)
        default:
            break
        }
    }

    /// The floor: read the pointer on a schedule.
    ///
    /// A `Task` rather than a `Timer`, and only while recording — the agent's zero-timer
    /// rule is about the idle process, and this exists solely between start and stop.
    private func startSampler() {
        samplerTask = Task { [weak self] in
            let interval = Duration.seconds(1 / TelemetryPolicy.sampleRate)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, isRecording else { return }
                recordPointer(at: NSEvent.mouseLocation)
            }
        }
    }

    // MARK: - Key mapping

    /// The named keys worth captioning, by virtual key code.
    ///
    /// A table rather than a switch: this is a lookup, and writing it as control flow both
    /// reads as a decision it is not and counts against the complexity budget.
    private static let specialKeyCodes: [UInt16: TelemetryPolicy.SpecialKey] = [
        36: .returnKey,
        76: .enter,
        48: .tab,
        53: .escape,
        51: .delete,
        117: .forwardDelete,
        126: .upArrow,
        125: .downArrow,
        123: .leftArrow,
        124: .rightArrow,
        116: .pageUp,
        121: .pageDown,
        115: .home,
        119: .end,
        49: .space
    ]

    private static func specialKey(for keyCode: UInt16) -> TelemetryPolicy.SpecialKey? {
        specialKeyCodes[keyCode]
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> TelemetryPolicy.Modifiers {
        var modifiers = TelemetryPolicy.Modifiers()
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.function) {
            modifiers.insert(.function)
        }
        return modifiers
    }
}
