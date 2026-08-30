import CoreGraphics
import CoreImage
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Finding the event in force at an instant (docs/10 R1.2).
///
/// The correctness half is table-driven, because a binary search is exactly the kind of
/// code that works for every case somebody thought of and fails on the empty array. The
/// cost half asserts the property the change exists for: per-frame work must not grow with
/// the length of the recording.
@Suite("Time-sorted lookup")
struct TimeSortedLookupTests {
    private struct Event {
        let time: TimeInterval
    }

    private func events(_ times: [TimeInterval]) -> [Event] {
        times.map(Event.init(time:))
    }

    // MARK: - Finding the one in force

    @Test(
        "The last element at or before the instant",
        arguments: [
            (0.0, 0), (0.5, 0), (1.0, 1), (1.5, 1), (2.0, 2), (99.0, 2)
        ]
    )
    func findsTheLastAtOrBefore(time: TimeInterval, expected: Int) {
        let index = TimeSortedLookup.lastIndex(atOrBefore: time, in: events([0, 1, 2]), key: \.time)
        #expect(index == expected)
    }

    @Test("Before the first element there is nothing in force")
    func beforeTheFirst() {
        #expect(TimeSortedLookup.lastIndex(atOrBefore: -1, in: events([0, 1, 2]), key: \.time) == nil)
    }

    @Test("An empty timeline has nothing in force")
    func empty() {
        #expect(TimeSortedLookup.lastIndex(atOrBefore: 5, in: [Event](), key: \.time) == nil)
    }

    @Test("A single element is found, or not, correctly")
    func singleElement() {
        #expect(TimeSortedLookup.lastIndex(atOrBefore: 5, in: events([3]), key: \.time) == 0)
        #expect(TimeSortedLookup.lastIndex(atOrBefore: 1, in: events([3]), key: \.time) == nil)
    }

    /// Two samples at the same instant is ordinary — a click and its pointer sample land
    /// together — and the later one is the one in force.
    @Test("Duplicate timestamps resolve to the last of them")
    func duplicateTimestamps() {
        #expect(TimeSortedLookup.lastIndex(atOrBefore: 1, in: events([1, 1, 1]), key: \.time) == 2)
    }

    /// The property that matters more than any single case: the binary search agrees with
    /// the obvious linear answer everywhere.
    @Test("The search agrees with a linear scan at every instant")
    func agreesWithLinearScan() {
        let times = (0 ..< 200).map { Double($0) * 0.37 }
        let list = events(times)
        for step in 0 ..< 400 {
            let time = Double(step) * 0.2
            let binary = TimeSortedLookup.lastIndex(atOrBefore: time, in: list, key: \.time)
            let linear = list.lastIndex { $0.time <= time }
            #expect(binary == linear, "disagreed at \(time)")
        }
    }

    // MARK: - Windows

    @Test("A window collects everything inside it, newest last")
    func windowCollects() {
        let found = TimeSortedLookup.elements(
            within: 1,
            endingAt: 10,
            in: events([8.5, 9.2, 9.8, 10.0]),
            key: \.time
        )
        #expect(found.map(\.time) == [9.2, 9.8, 10.0])
    }

    @Test("A window with nothing recent enough is empty")
    func windowExpires() {
        let found = TimeSortedLookup.elements(within: 1, endingAt: 10, in: events([2, 3]), key: \.time)
        #expect(found.isEmpty)
    }

    @Test("A window before anything happened is empty")
    func windowBeforeAnything() {
        let found = TimeSortedLookup.elements(within: 1, endingAt: 0, in: events([5, 6]), key: \.time)
        #expect(found.isEmpty)
    }

    @Test("A window over an empty timeline is empty")
    func windowOverNothing() {
        #expect(TimeSortedLookup.elements(within: 1, endingAt: 5, in: [Event](), key: \.time).isEmpty)
    }

    // MARK: - The cost

    /// What the change is for. Per-frame work must not grow with the recording's length —
    /// before this, composing one frame scanned every telemetry sample from the end, so a
    /// ten-minute session cost twenty-five times what a one-minute session did *per frame*,
    /// and the total grew quadratically.
    ///
    /// Timed rather than counted, because the thing being asserted is a cost. The ratio is
    /// generous: it separates "grows with N" from "does not", and a machine under load
    /// moves both numbers together.
    @Test("Composing a frame costs the same on a long recording as a short one")
    func perFrameCostIsFlat() throws {
        let small = try measureCompose(sampleCount: 1000)
        let large = try measureCompose(sampleCount: 100_000)

        // A hundred times the telemetry must not cost more than 20% extra per frame
        // (docs/10 R2.7). Linear scanning would be about 100×.
        #expect(
            large < small * 1.2,
            "100× the telemetry cost \(large / max(small, .leastNonzeroMagnitude))× the time per frame"
        )
    }

    /// Composes a fixed number of frames over a synthetic session and returns the seconds
    /// per frame.
    private func measureCompose(sampleCount: Int) throws -> Double {
        let size = CGSize(width: 320, height: 180)
        let duration = Double(sampleCount) / 60

        var telemetry = InputTelemetry()
        telemetry.pointer = (0 ..< sampleCount).map { step in
            PointerSample(
                time: Double(step) / 60,
                position: CGPoint(x: Double(step % 300), y: 90),
                cursorIndex: nil
            )
        }
        telemetry.clicks = stride(from: 0, to: sampleCount, by: 200).map { step in
            ClickEvent(time: Double(step) / 60, position: CGPoint(x: 100, y: 90))
        }
        telemetry.keystrokes = stride(from: 0, to: sampleCount, by: 300).map { step in
            KeystrokeEvent(time: Double(step) / 60, caption: "⌘S")
        }

        var edit = StudioEdit.untouched(duration: duration)
        edit.showsClicks = true
        edit.showsKeystrokes = true

        let plan = StudioRenderPlan(edit: edit, sourceSize: size)
        let composer = StudioFrameComposer(plan: plan, edit: edit, telemetry: telemetry)
        let source = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: size))

        // Warmed first. Without this the smaller case pays for CoreImage's first-use setup
        // and measures ten times *slower* than the larger one — a test that passes while
        // measuring start-up rather than the thing it claims to.
        for step in 0 ..< 10 {
            _ = composer.frame(at: duration * Double(step) / 10, source: source, camera: nil)
        }

        // Sampled across the whole recording, so the lookups cannot be helped by every
        // query landing at the same place.
        let frames = 60
        let start = ContinuousClock.now
        for step in 0 ..< frames {
            _ = composer.frame(
                at: duration * Double(step) / Double(frames),
                source: source,
                camera: nil
            )
        }
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.attoseconds) / 1e18 / Double(frames)
    }
}
