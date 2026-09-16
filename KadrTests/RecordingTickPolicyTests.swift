import CoreGraphics
import CoreVideo
import Foundation
import RecordingCore
import Shared
import Testing
@testable import Kadr

/// What a recording costs while it runs (PRD §8).
///
/// The tick runs at 10 Hz for the level meter. It used to notify the menu bar on every one
/// of those ticks, which rebuilt the status-item icon and rewrote the floating bar ten
/// times a second for a clock that changes once.
@MainActor
@Suite("Recording tick")
struct RecordingTickPolicyTests {
    private nonisolated static func display(_ seconds: Int, silent: Bool = false) -> RecordingTickDisplay {
        RecordingTickDisplay(wholeSeconds: seconds, microphoneIsSilent: silent)
    }

    @Test("Only a change somebody can see notifies", arguments: [
        (display(0), display(0), false),
        (display(4), display(4), false),
        (display(4), display(5), true),
        (display(59), display(60), true),
        (display(5), display(0), true),
        (display(3), display(3, silent: true), true),
        (display(3, silent: true), display(3), true),
        (display(3, silent: true), display(3, silent: true), false)
    ])
    func notifiesOnVisibleChange(previous: RecordingTickDisplay, next: RecordingTickDisplay, notifies: Bool) {
        #expect(RecordingTickPolicy.shouldNotify(previous: previous, next: next) == notifies)
    }

    /// Ten ticks inside one second are one clock value, so they are at most one
    /// notification — the one at the second boundary.
    @Test("A second of ticks is at most one notification", arguments: [0.0, 0.05, 0.95, 12.3])
    func tenTicksOneNotification(start: TimeInterval) {
        var notifications = 0
        var previous = Self.display(Int(start))
        for tick in 1 ... 10 {
            let next = Self.display(Int(start + Double(tick) * 0.1))
            if RecordingTickPolicy.shouldNotify(previous: previous, next: next) {
                notifications += 1
            }
            previous = next
        }
        #expect(notifications <= 1)
    }

    @Test("A microphone is silent only once it has had a chance to hear something", arguments: [
        (true, 0.5, Float(0), false),
        (true, 2.0, Float(0), false),
        (true, 2.1, Float(0), true),
        (true, 10, AudioMeter.silence, false),
        (true, 10, Float(0.5), false),
        (false, 10, Float(0), false)
    ])
    func silence(recordsMicrophone: Bool, elapsed: TimeInterval, peak: Float, silent: Bool) {
        #expect(RecordingTickPolicy.microphoneIsSilent(
            recordsMicrophone: recordsMicrophone,
            elapsed: elapsed,
            peak: peak
        ) == silent)
    }

    @Test("The meter model ignores a level it already shows")
    func meterSkipsUnchanged() {
        let meter = RecordingAudioMeterModel()
        let changes = ChangeCounter()
        func observe() {
            withObservationTracking {
                _ = meter.level
            } onChange: {
                changes.increment()
            }
        }
        observe()
        meter.set(0)
        #expect(changes.value == 0)
        meter.set(0.4)
        #expect(changes.value == 1)
        observe()
        meter.set(0.4)
        #expect(changes.value == 1)
    }

    @Test("The bar model rewrites only what changed")
    func barModelSkipsUnchanged() {
        let model = RecordingControlBarModel()
        let controls = RecordingControls(
            elapsedText: "0:05",
            isPaused: false,
            stop: {},
            togglePause: {},
            cancel: {}
        )
        model.apply(controls)
        let changes = ChangeCounter()
        withObservationTracking {
            _ = model.elapsedText
            _ = model.isPaused
            _ = model.microphoneIsSilent
            _ = model.notice
            _ = model.isTransitioning
        } onChange: {
            changes.increment()
        }
        model.apply(controls)
        #expect(changes.value == 0, "the same controls again must not invalidate the bar")
    }
}

/// Counts observation callbacks, which arrive on a `@Sendable` closure.
private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// The baked-in webcam asks the camera for frames the size it draws them (PRD §8).
@MainActor
@Suite("Webcam sizing")
struct WebcamSizingTests {
    struct SizingCase: Sendable {
        let native: PixelSize
        let side: Int
        let expected: PixelSize?
    }

    @Test("The camera is asked for the bubble's size, never more than it has", arguments: [
        SizingCase(native: PixelSize(width: 480, height: 360), side: 180, expected: PixelSize(width: 240, height: 180)),
        SizingCase(
            native: PixelSize(width: 1280, height: 720),
            side: 360,
            expected: PixelSize(width: 640, height: 360)
        ),
        SizingCase(native: PixelSize(width: 480, height: 360), side: 360, expected: nil),
        SizingCase(native: PixelSize(width: 480, height: 360), side: 500, expected: nil),
        SizingCase(native: PixelSize(width: 640, height: 480), side: 1, expected: PixelSize(width: 2, height: 2)),
        SizingCase(native: PixelSize(width: 360, height: 480), side: 120, expected: PixelSize(width: 120, height: 160)),
        SizingCase(native: PixelSize(width: 0, height: 0), side: 100, expected: nil)
    ])
    func outputSize(sizing: SizingCase) {
        let size = WebcamOutputSizing.size(
            nativeWidth: sizing.native.width,
            nativeHeight: sizing.native.height,
            shortEdge: sizing.side
        )
        #expect(size.map { PixelSize(width: $0.width, height: $0.height) } == sizing.expected)
        if let size {
            #expect(size.width % 2 == 0 && size.height % 2 == 0)
        }
    }

    struct BubbleCase: Sendable {
        let recorded: PixelSize
        let fraction: CGFloat
        let fillsFrame: Bool
        let side: Int?
    }

    @Test("The bubble's side follows the compositor's geometry", arguments: [
        BubbleCase(recorded: PixelSize(width: 2880, height: 1800), fraction: 0.22, fillsFrame: false, side: 396),
        BubbleCase(recorded: PixelSize(width: 1800, height: 2880), fraction: 0.22, fillsFrame: false, side: 396),
        BubbleCase(recorded: PixelSize(width: 1920, height: 1080), fraction: 0.5, fillsFrame: false, side: 540),
        BubbleCase(recorded: PixelSize(width: 1920, height: 1080), fraction: 0.22, fillsFrame: true, side: 1080),
        BubbleCase(recorded: PixelSize(width: 2, height: 2), fraction: 0.1, fillsFrame: false, side: nil)
    ])
    func bubbleSide(bubble: BubbleCase) {
        #expect(RecordingCoordinator.webcamPixelSide(
            recordedPixels: bubble.recorded,
            sizeFraction: bubble.fraction,
            fillsFrame: bubble.fillsFrame
        ) == bubble.side)
    }

    @Test("A window recording leaves the camera at its own size")
    func windowHasNoSide() {
        #expect(RecordingCoordinator.webcamPixelSide(recordedPixels: nil, sizeFraction: 0.22, fillsFrame: false) == nil)
        #expect(RecordingCoordinator.recordedPixelSize(for: .window(1)) == nil)
    }

    @Test("A region's recorded size is its points at the display's scale")
    func regionSize() {
        let display = CGMainDisplayID()
        let size = RecordingCoordinator.recordedPixelSize(
            for: .region(DisplayRect(x: 0, y: 0, width: 300, height: 200), display: display)
        )
        let scale = RecordingCoordinator.pointPixelScale(for: .display(display))
        #expect(size == PixelSize(width: Int(300 * scale), height: Int(200 * scale)))
    }

    /// The camera frame is wrapped rather than copied, so the image must read the buffer's
    /// own bytes — and keep them valid after the caller has let the buffer go.
    @Test("A wrapped camera frame reads the buffer's pixels and outlives the caller's reference")
    func wrappedFrameReadsPixels() throws {
        // The buffer exists only inside the helper; the image is all that comes back.
        let image = try #require(Self.wrappedRedFrame())
        #expect(image.width == 8)
        #expect(image.height == 4)

        let data = try #require(image.dataProvider?.data as Data?)
        // BGRA: blue, green, red, alpha.
        #expect(data[0] == 0x00)
        #expect(data[2] == 0xFF)
        #expect(data[3] == 0xFF)
    }

    private static func wrappedRedFrame() -> CGImage? {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            4,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &created
        )
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            for offset in stride(from: 0, to: bytes, by: 4) {
                base.storeBytes(of: 0x00, toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: 0x00, toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(of: 0xFF, toByteOffset: offset + 2, as: UInt8.self)
                base.storeBytes(of: 0xFF, toByteOffset: offset + 3, as: UInt8.self)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return WebcamFrameImage.image(wrapping: buffer)
    }

    @Test("A frame that is not BGRA is refused")
    func refusesOtherFormats() throws {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &created)
        let buffer = try #require(created)
        #expect(WebcamFrameImage.image(wrapping: buffer) == nil)
    }
}
