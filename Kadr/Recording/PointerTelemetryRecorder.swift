import AppKit
import CoreGraphics
import Foundation
import os
import Shared
import StudioSession

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
    let logger = KadrLog.logger(.recording)

    private var pointer: [PointerSample] = []
    private var clicks: [ClickEvent] = []
    private var keystrokes: [KeystrokeEvent] = []
    private var cursors: [CursorImage] = []
    /// Cursor artwork already captured, keyed by its bytes, so a session holds one copy of
    /// each cursor rather than one per sample.
    private var cursorIndices: [Data: Int] = [:]

    private var source: TelemetrySource = .sampler
    var isRecording = false
    private var journal: TelemetryJournal?
    /// Last recording-time a chunk was flushed. Zero until the first sample.
    private var lastFlushTime: TimeInterval = 0

    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var monitors: [Any] = []
    var samplerTask: Task<Void, Never>?

    /// Where the recording is now, in its own time. Set by the engine as it composites, so
    /// the sidecar and the footage share one clock — the fix docs/07 M2 made for the live
    /// overlay, applied from the start here.
    private var recordingTime: TimeInterval = 0
    /// Maps a screen point into the recorded area's pixels.
    /// Screen space in, recorded pixels out (docs/11 S0.1).
    ///
    /// Typed, because the two global point spaces on macOS are vertical mirrors of each
    /// other and both are spelled `CGPoint`.
    private var pointConverter: @Sendable (ScreenPoint) -> PixelPoint? = { PixelPoint(x: $0.x, y: $0.y) }
    /// The flip axis between the two global spaces, read when the recording starts.
    var space = GlobalCoordinateSpace.current

    var isActive: Bool {
        isRecording
    }

    // MARK: - Lifecycle

    /// How often in-memory samples are flushed to the sidecar journal.
    ///
    /// A minute of 60 Hz pointer samples is about 150 KB. Holding the whole recording
    /// would be 2.4 KB/s unbounded — 8.6 MB after an hour, with a 17 MB spike at the
    /// array-doubling (docs/10 R2.5).
    private static let flushInterval: TimeInterval = 60

    /// Starts watching. Nothing is installed until this is called, and everything is torn
    /// down by `stop` — an idle agent has no tap, no monitors and no timer.
    func start(
        pointConverter: @escaping @Sendable (ScreenPoint) -> PixelPoint?,
        space: GlobalCoordinateSpace = .current,
        journalURL: URL? = nil
    ) {
        guard !isRecording else { return }
        self.pointConverter = pointConverter
        // Passed in rather than read here, so a test can describe the display arrangement
        // it is asserting about. The flip axis is the primary display's height, and a test
        // that had to match whatever machine it ran on would assert nothing portable.
        self.space = space
        pointer = []
        clicks = []
        keystrokes = []
        cursors = []
        cursorIndices = [:]
        cursorFingerprints = [:]
        lastCursorIndex = nil
        lastCursorCheck = -.infinity
        recordingTime = 0
        lastFlushTime = 0
        isRecording = true
        // One minute of 60 Hz samples, plus headroom so the first flush does not reallocate.
        pointer.reserveCapacity(Int(TelemetryPolicy.sampleRate * Self.flushInterval) + 16)
        clicks.reserveCapacity(256)
        keystrokes.reserveCapacity(128)
        if let journalURL {
            journal = TelemetryJournal(url: journalURL)
            journal?.remove()
        } else {
            journal = nil
        }

        // One rung, not all of them (docs/11 S0.2). This used to start the tap *and* the
        // monitors and then merely label which had won, so both fed the recorder: every
        // press produced two events at the same instant, and after C1's mirror one of the
        // two was in the wrong place. The ladder is a fallback, not a chorus.
        let hasEventTap = startEventTap()
        let hasMonitors = hasEventTap ? false : startMonitors()
        source = TelemetryPolicy.source(for: TelemetryPolicy.Availability(
            hasEventTap: hasEventTap,
            hasAppKitMonitors: hasMonitors
        ))
        // Keystrokes always come from a monitor: the tap's mask carries no `keyDown`, so
        // the tap winning the pointer does not mean it can hear the keyboard.
        startKeystrokeMonitor()
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

        flush(force: true)
        let flushed = journal?.load() ?? TelemetryJournal.Chunk()
        journal = nil

        return InputTelemetry(
            pointer: flushed.pointer + pointer,
            clicks: flushed.clicks + clicks,
            keystrokes: flushed.keystrokes + keystrokes,
            cursors: cursors,
            source: source
        )
    }

    /// Tells the recorder where the recording is, so events are stamped in the same clock
    /// the frames are.
    func advance(to time: TimeInterval) {
        recordingTime = time
        flush(force: false)
    }

    /// Writes the in-memory samples to the journal and drops them, keeping capacity.
    private func flush(force: Bool) {
        guard let journal else { return }
        guard force || recordingTime - lastFlushTime >= Self.flushInterval else { return }
        let chunk = TelemetryJournal.Chunk(pointer: pointer, clicks: clicks, keystrokes: keystrokes)
        do {
            try journal.append(chunk)
            pointer.removeAll(keepingCapacity: true)
            clicks.removeAll(keepingCapacity: true)
            keystrokes.removeAll(keepingCapacity: true)
            lastFlushTime = recordingTime
        } catch {
            logger.error("Could not flush telemetry: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Recording events

    func recordPointer(at screenPoint: ScreenPoint) {
        guard isRecording, let position = pointConverter(screenPoint)?.cgPoint else { return }
        guard TelemetryPolicy.shouldRecord(position, at: recordingTime, lastSample: pointer.last) else {
            return
        }
        pointer.append(PointerSample(
            time: recordingTime,
            position: position,
            cursorIndex: captureCurrentCursor()
        ))
    }

    func recordClick(at screenPoint: ScreenPoint, button: ClickEvent.Button, isDown: Bool) {
        guard isRecording, let position = pointConverter(screenPoint)?.cgPoint else { return }
        // One event per physical click (docs/11 S0.2). Both rungs of the ladder used to
        // run at once and only the *label* said which had won, so every press appended
        // two events at the same instant — and after the mirror above, one of them was in
        // the wrong place. The ladder now tears the loser down, and this is the belt to
        // those braces: a duplicate at the same time, button and state is the same click
        // seen twice, and a real double-click is two presses milliseconds apart.
        if isDuplicate(of: clicks.last, button: button, isDown: isDown) {
            return
        }
        clicks.append(ClickEvent(
            time: recordingTime,
            position: position,
            button: button,
            isDown: isDown
        ))
    }

    /// Whether this event is one the recorder has already seen.
    ///
    /// The same button, in the same state, within a hair of the same instant is one
    /// physical click observed twice rather than two clicks.
    private func isDuplicate(of last: ClickEvent?, button: ClickEvent.Button, isDown: Bool) -> Bool {
        guard let last else { return false }
        return last.button == button
            && last.isDown == isDown
            && recordingTime - last.time < Self.clickCoalescingWindow
    }

    /// Two presses closer together than this are one press seen twice.
    ///
    /// Well under the shortest deliberate double-click — macOS's own maximum interval is
    /// a quarter of a second — so a real double-click still records two events.
    private static let clickCoalescingWindow: TimeInterval = 0.01

    // MARK: - Seams

    /// Drives one pointer event, for a test that has no event tap.
    ///
    /// The tap needs an accessibility grant and a real pointer; the *clock* needs neither,
    /// and the clock is what was broken. Declaring the whole of telemetry untestable is how
    /// a frozen timestamp shipped through a suite that passed.
    func recordPointerForTesting(at screenPoint: ScreenPoint) {
        recordPointer(at: screenPoint)
    }

    func recordClickForTesting(at screenPoint: ScreenPoint) {
        recordClick(at: screenPoint, button: .left, isDown: true)
    }

    /// Drives the tap's own path, in the space a `CGEvent` actually uses.
    ///
    /// The seam C1 lived on: a test that only calls `recordPointerForTesting` never
    /// exercises the conversion the tap has to perform, which is precisely why an identity
    /// converter and 1,688 passing tests missed a vertical mirror.
    func recordTapEventForTesting(type: CGEventType, at displayLocation: CGPoint) {
        handleTapEvent(type: type, at: displayLocation)
    }

    func recordMonitorEventForTesting(type: NSEvent.EventType, at screenLocation: CGPoint) {
        handleMonitorEvent(type: type, at: screenLocation)
    }

    func recordKeystroke(characters: String?, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
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
}
