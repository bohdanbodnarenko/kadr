import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

/// Moving telemetry from the recording's clock onto the edit's (docs/10 R0.2).
///
/// The bug this guards is invisible on an untouched recording, which is why it survived a
/// suite that passed: source time and edited time are the same number until somebody cuts
/// something. Every test here therefore cuts or re-times first.
@Suite("Telemetry rebasing")
struct TelemetryRebasingTests {
    private func telemetry(clickTimes: [TimeInterval]) -> InputTelemetry {
        var telemetry = InputTelemetry()
        telemetry.clicks = clickTimes.map { ClickEvent(time: $0, position: CGPoint(x: 100, y: 100)) }
        telemetry.pointer = clickTimes.map { PointerSample(time: $0, position: CGPoint(x: 100, y: 100)) }
        telemetry.keystrokes = clickTimes.map { KeystrokeEvent(time: $0, caption: "⌘S") }
        return telemetry
    }

    // MARK: - The untouched case

    /// An untouched timeline maps source time to itself, and the common case should cost
    /// nothing at all.
    @Test("An untouched recording is returned unchanged")
    func untouchedIsUnchanged() {
        let original = telemetry(clickTimes: [1, 5, 9])
        let rebased = original.rebased(to: .whole(duration: 20))
        #expect(rebased == original)
    }

    @Test("A whole timeline is not considered edited")
    func wholeTimelineIsNotEdited() {
        #expect(!ClipTimeline.whole(duration: 10).isEdited(ofRecordingLasting: 10))
        #expect(ClipTimeline(clips: [Clip(sourceStart: 2, sourceDuration: 8)]).isEdited(ofRecordingLasting: 10))
        #expect(ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 8, speed: 2)])
            .isEdited(ofRecordingLasting: 10))
        // Trimmed at the end and nowhere else: one clip, starting at zero, natural speed,
        // just shorter. This reported itself unedited, so telemetry took the fast path and
        // kept every click from the part the user had cut off (docs/11 S2).
        #expect(ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 8)]).isEdited(ofRecordingLasting: 10))
        // And a rounding wobble is not an edit.
        #expect(!ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 9.999)]).isEdited(ofRecordingLasting: 10))
    }

    // MARK: - Cutting

    /// The headline case from the review: cut ten seconds from the middle, and everything
    /// after the cut has to move earlier by ten seconds. Before this, a ripple recorded at
    /// 25 s fired at 25 s of a timeline that was only 20 s long — against whatever footage
    /// happened to be there.
    @Test("A cut moves everything after it earlier")
    func cutMovesLaterEventsEarlier() {
        // Keep 0–10 and 20–30 of a 30-second recording: ten seconds removed from the middle.
        let clips = ClipTimeline(clips: [
            Clip(sourceStart: 0, sourceDuration: 10),
            Clip(sourceStart: 20, sourceDuration: 10)
        ])
        let rebased = telemetry(clickTimes: [5, 25]).rebased(to: clips)

        #expect(rebased.clicks.count == 2)
        #expect(abs((rebased.clicks.first?.time ?? -1) - 5) < 0.001, "a click before the cut moved")
        // 25 s of source is 15 s of edit: ten seconds of it were removed.
        #expect(abs((rebased.clicks.last?.time ?? -1) - 15) < 0.001, "the click after the cut is at the wrong time")
    }

    /// A click that happened in footage the user removed did not happen in the edit. Piling
    /// those against the cut point would put a burst of ripples exactly at the join, which
    /// is the one moment the eye is already watching.
    @Test("An event inside a cut is dropped rather than clamped")
    func eventsInsideACutAreDropped() {
        let clips = ClipTimeline(clips: [
            Clip(sourceStart: 0, sourceDuration: 10),
            Clip(sourceStart: 20, sourceDuration: 10)
        ])
        let rebased = telemetry(clickTimes: [5, 14, 25]).rebased(to: clips)
        #expect(rebased.clicks.count == 2, "the click inside the removed stretch survived")
        #expect(!rebased.clicks.contains { abs($0.time - 14) < 0.001 })
    }

    // MARK: - Speed

    /// Set a clip to 2× and the cursor used to play at half the picture's speed, because
    /// its samples were still stamped in the footage's own time.
    @Test("A sped-up clip pulls its events closer together")
    func speedCompressesEvents() {
        let clips = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 20, speed: 2)])
        let rebased = telemetry(clickTimes: [0, 10, 20]).rebased(to: clips)

        let times = rebased.clicks.map(\.time)
        #expect(times.count >= 2)
        // Ten seconds of footage at 2× is five seconds of edit.
        #expect(abs((times.first ?? -1) - 0) < 0.001)
        #expect(abs(times[1] - 5) < 0.001, "a click ten seconds in landed at \(times[1]) rather than 5")
    }

    /// Speed is clamped at 1 — below it the audio is unintelligible and the footage reads
    /// as broken rather than slow — so a rebase can only ever pull events closer together.
    /// Asserted so the invariant is stated somewhere the rebasing can see it: a future
    /// slow-motion clip would need this test rewritten, not silently inverted.
    @Test("Slower than real time is not in the domain, so nothing spreads apart")
    func slowMotionIsNotSupported() {
        let clips = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 10, speed: 0.5)])
        #expect(clips.clips.first?.speed == 1, "speed clamps at real time")

        let rebased = telemetry(clickTimes: [0, 5]).rebased(to: clips)
        #expect(abs((rebased.clicks.last?.time ?? -1) - 5) < 0.001)
    }

    // MARK: - Everything moves together

    /// All four streams are stamped in the same clock, so all four have to be converted —
    /// a rebase that moved the clicks and left the pointer behind would put the cursor and
    /// its ripple in different places.
    @Test("Pointer samples, clicks, chords and geometry all move")
    func everyStreamIsRebased() {
        let clips = ClipTimeline(clips: [
            Clip(sourceStart: 0, sourceDuration: 10),
            Clip(sourceStart: 20, sourceDuration: 10)
        ])
        var original = telemetry(clickTimes: [5, 25])
        original.windowGeometry = [
            WindowGeometrySample(time: 5, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            WindowGeometrySample(time: 25, frame: CGRect(x: 50, y: 0, width: 100, height: 100))
        ]
        let rebased = original.rebased(to: clips)

        #expect(abs((rebased.pointer.last?.time ?? -1) - 15) < 0.001)
        #expect(abs((rebased.keystrokes.last?.time ?? -1) - 15) < 0.001)
        #expect(abs((rebased.windowGeometry.last?.time ?? -1) - 15) < 0.001)
    }

    @Test("The cursor artwork is carried across unchanged")
    func cursorsSurvive() {
        var original = telemetry(clickTimes: [5])
        original.cursors = [CursorImage(pngData: Data([1, 2, 3]), hotspot: .zero, size: CGSize(width: 20, height: 20))]
        let rebased = original.rebased(to: ClipTimeline(clips: [Clip(sourceStart: 2, sourceDuration: 8)]))
        #expect(rebased.cursors == original.cursors, "the cursor images are not timestamped and must survive intact")
    }

    // MARK: - Edges

    @Test("Empty telemetry rebases to empty telemetry")
    func emptyIsEmpty() {
        let rebased = InputTelemetry().rebased(to: ClipTimeline(clips: [Clip(sourceStart: 5, sourceDuration: 5)]))
        #expect(rebased.pointer.isEmpty)
        #expect(rebased.clicks.isEmpty)
    }

    @Test("Events before the first clip are dropped")
    func eventsBeforeTheFirstClipAreDropped() {
        let clips = ClipTimeline(clips: [Clip(sourceStart: 10, sourceDuration: 10)])
        let rebased = telemetry(clickTimes: [2, 15]).rebased(to: clips)
        #expect(rebased.clicks.count == 1)
        #expect(abs((rebased.clicks.first?.time ?? -1) - 5) < 0.001)
    }

    /// The order the studio relies on everywhere: `last { $0.time <= now }` is only correct
    /// on a sorted array, and rebasing must not shuffle one.
    @Test("Rebasing keeps the events in order")
    func orderIsPreserved() {
        let clips = ClipTimeline(clips: [
            Clip(sourceStart: 0, sourceDuration: 10),
            Clip(sourceStart: 20, sourceDuration: 10)
        ])
        let rebased = telemetry(clickTimes: [1, 3, 7, 21, 25, 29]).rebased(to: clips)
        let times = rebased.clicks.map(\.time)
        #expect(times == times.sorted())
    }

    /// The defect the parameter exists for, through `rebased(to:)` rather than through the
    /// predicate: a recording trimmed at the end must not keep the telemetry from the part
    /// that was cut off (docs/11 S2).
    @Test("Trimming the end drops the telemetry past the trim")
    func trimmingTheEndDropsLateEvents() {
        var telemetry = InputTelemetry()
        telemetry.clicks = [
            ClickEvent(time: 1, position: CGPoint(x: 10, y: 10)),
            ClickEvent(time: 9, position: CGPoint(x: 20, y: 20))
        ]
        telemetry.keystrokes = [
            KeystrokeEvent(time: 2, caption: "A"),
            KeystrokeEvent(time: 8.5, caption: "B")
        ]

        // One clip, starting at zero, natural speed — just shorter than the recording.
        let trimmed = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 5)])
        let rebased = telemetry.rebased(to: trimmed)

        #expect(rebased.clicks.map(\.time) == [1], "a click from the trimmed-off tail survived")
        #expect(rebased.keystrokes.map(\.caption) == ["A"])
    }

    /// And the fast path still exists, because it is most recordings most of the time.
    @Test("An untrimmed recording is returned unchanged")
    func untrimmedIsUntouched() {
        var telemetry = InputTelemetry()
        telemetry.clicks = [ClickEvent(time: 9, position: CGPoint(x: 20, y: 20))]
        let rebased = telemetry.rebased(to: ClipTimeline.whole(duration: 10))
        #expect(rebased.clicks.map(\.time) == [9])
    }
}
