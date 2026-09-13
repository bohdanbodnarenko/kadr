import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

/// Cutting and retiming without touching the footage (docs/09 U3.4).
///
/// The time mapping is the part everything else depends on: zoom cues, the cursor
/// reconstruction and the export all work in edited time, while the telemetry arrives in
/// source time. One place converts, so these tests are where that conversion is pinned.
@Suite("Clip timeline")
struct ClipTimelineTests {
    private func whole(_ duration: TimeInterval = 10) -> ClipTimeline {
        ClipTimeline.whole(duration: duration)
    }

    // MARK: - The uncut case

    @Test("An uncut recording maps time to itself")
    func uncutIsIdentity() throws {
        let timeline = whole()
        #expect(timeline.editedDuration == 10)
        for time in stride(from: 0.0, through: 9.9, by: 0.5) {
            #expect(try abs(#require(timeline.sourceTime(forEdited: time)) - time) < 0.001)
            #expect(try abs(#require(timeline.editedTime(forSource: time)) - time) < 0.001)
        }
    }

    @Test("Past the end there is no frame, which is an answer rather than a failure")
    func pastTheEnd() {
        #expect(whole(5).sourceTime(forEdited: 6) == nil)
        #expect(whole(5).sourceTime(forEdited: -1) == nil)
    }

    // MARK: - Splitting

    /// Two adjacent clips play exactly as one did, which is what makes splitting safe to
    /// do speculatively.
    @Test("A split changes nothing until something else does")
    func splitChangesNothing() throws {
        var timeline = whole()
        timeline.split(atEdited: 4)

        #expect(timeline.clips.count == 2)
        #expect(abs(timeline.editedDuration - 10) < 0.001)
        for time in stride(from: 0.0, through: 9.9, by: 0.5) {
            #expect(try abs(#require(timeline.sourceTime(forEdited: time)) - time) < 0.001)
        }
    }

    @Test("A split at the very start or end does nothing")
    func splitAtTheEdges() {
        var timeline = whole()
        timeline.split(atEdited: 0)
        timeline.split(atEdited: 10)
        #expect(timeline.clips.count == 1)
    }

    /// Cutting is removing a clip, and the footage is untouched — which is why undo is
    /// putting the clip back rather than restoring bytes nobody kept.
    @Test("Removing a clip shortens the video and leaves the recording alone")
    func removingAClip() throws {
        var timeline = whole()
        timeline.split(atEdited: 4)
        timeline.remove(timeline.clips[0].id)

        #expect(abs(timeline.editedDuration - 6) < 0.001)
        // What is now at zero is what used to be at four.
        #expect(try abs(#require(timeline.sourceTime(forEdited: 0)) - 4) < 0.001)
    }

    /// A moment that was cut out has no place in the finished video, and saying so is the
    /// answer a cue anchored there needs.
    @Test("A cut-out moment maps to nothing")
    func cutMomentHasNoEditedTime() {
        var timeline = whole()
        timeline.split(atEdited: 4)
        timeline.remove(timeline.clips[0].id)

        #expect(timeline.editedTime(forSource: 2) == nil, "that moment was removed")
        #expect(timeline.editedTime(forSource: 5) != nil)
    }

    // MARK: - Speed

    @Test("Doubling the speed halves the time it takes")
    func speedShortens() {
        var timeline = whole()
        timeline.setSpeed(2, for: timeline.clips[0].id)
        #expect(abs(timeline.editedDuration - 5) < 0.001)
    }

    @Test("A sped-up clip maps time proportionally")
    func speedMapsTime() throws {
        var timeline = whole()
        timeline.setSpeed(2, for: timeline.clips[0].id)

        #expect(try abs(#require(timeline.sourceTime(forEdited: 1)) - 2) < 0.001)
        #expect(try abs(#require(timeline.editedTime(forSource: 6)) - 3) < 0.001)
    }

    @Test("Speed is per clip, not per timeline")
    func speedIsPerClip() throws {
        var timeline = whole()
        timeline.split(atEdited: 5)
        timeline.setSpeed(2, for: timeline.clips[1].id)

        #expect(abs(timeline.editedDuration - 7.5) < 0.001)
        // The first clip is untouched.
        #expect(try abs(#require(timeline.sourceTime(forEdited: 2)) - 2) < 0.001)
    }

    /// Past eight times, a second of recording is an eighth of a second on screen and
    /// nothing in it can be followed.
    @Test("Speed is clamped to something watchable")
    func speedIsClamped() {
        #expect(Clip(sourceStart: 0, sourceDuration: 1, speed: 99).speed == Clip.maximumSpeed)
        #expect(Clip(sourceStart: 0, sourceDuration: 1, speed: 0.1).speed == Clip.minimumSpeed)
    }

    @Test("A split does not retime either half")
    func splitPreservesSpeed() {
        var timeline = whole()
        timeline.setSpeed(2, for: timeline.clips[0].id)
        timeline.split(atEdited: 2)

        #expect(timeline.clips.allSatisfy { $0.speed == 2 })
        #expect(abs(timeline.editedDuration - 5) < 0.001)
    }

    // MARK: - Rebasing cues

    /// Cues live in edited time because that is what the viewer experiences, but a cue
    /// generated from clicks starts life in source time.
    @Test("Cues are rewritten into edited time")
    func rebasingCues() throws {
        var timeline = whole()
        timeline.split(atEdited: 4)
        timeline.remove(timeline.clips[0].id)

        let cue = ZoomCue(start: 6, duration: 2)
        let rebased = try #require(timeline.rebasing([cue]).first)
        #expect(abs(rebased.start - 2) < 0.001, "six seconds in, minus the four that were cut")
    }

    /// Sliding a cue to a neighbouring moment would zoom into something the user never
    /// chose.
    @Test("A cue whose moment was cut is dropped rather than moved")
    func cuesInCutFootageAreDropped() {
        var timeline = whole()
        timeline.split(atEdited: 4)
        timeline.remove(timeline.clips[0].id)

        #expect(timeline.rebasing([ZoomCue(start: 2, duration: 1)]).isEmpty)
    }

    @Test("A cue in sped-up footage holds for proportionally less time")
    func cuesShortenWithSpeed() throws {
        var timeline = whole()
        timeline.setSpeed(2, for: timeline.clips[0].id)

        let rebased = try #require(timeline.rebasing([ZoomCue(start: 4, duration: 2)]).first)
        #expect(abs(rebased.start - 2) < 0.001)
        #expect(abs(rebased.duration - 1) < 0.001)
    }

    // MARK: - Degenerate input

    @Test("An empty timeline answers nothing rather than crashing")
    func emptyTimeline() {
        let timeline = ClipTimeline()
        #expect(timeline.isEmpty)
        #expect(timeline.editedDuration == 0)
        #expect(timeline.sourceTime(forEdited: 0) == nil)
        #expect(timeline.editedTime(forSource: 0) == nil)
        #expect(timeline.rebasing([ZoomCue(start: 1, duration: 1)]).isEmpty)
    }

    @Test("A timeline round-trips")
    func roundTrips() throws {
        var timeline = whole()
        timeline.split(atEdited: 4)
        timeline.setSpeed(2, for: timeline.clips[1].id)

        let data = try JSONEncoder().encode(timeline)
        #expect(try JSONDecoder().decode(ClipTimeline.self, from: data) == timeline)
    }

    @Test("A timeline with nothing in it at all decodes")
    func emptyObject() throws {
        #expect(try JSONDecoder().decode(ClipTimeline.self, from: Data("{}".utf8)).isEmpty)
    }

    // MARK: - Edge trim

    @Test("Dragging a clip's leading edge skips the start of that piece")
    func trimClipStart() throws {
        var timeline = whole()
        let id = timeline.clips[0].id
        timeline.trimClipStart(at: 0, toEdited: 2)
        #expect(abs(timeline.editedDuration - 8) < 0.001)
        #expect(try abs(#require(timeline.sourceTime(forEdited: 0)) - 2) < 0.001)
        #expect(timeline.clips[0].id == id)
    }

    @Test("Dragging a clip's trailing edge drops the end of that piece")
    func trimClipEnd() {
        var timeline = whole()
        let id = timeline.clips[0].id
        timeline.trimClipEnd(at: 0, toEdited: 7)
        #expect(abs(timeline.editedDuration - 7) < 0.001)
        #expect(timeline.clips[0].id == id)
        #expect(timeline.sourceTime(forEdited: 8) == nil)
    }

    @Test("An edge trim will not shrink a clip past the grab-able floor")
    func trimClipRespectsMinimum() {
        var timeline = whole(1)
        timeline.trimClipEnd(at: 0, toEdited: 0.01)
        #expect(abs(timeline.editedDuration - Clip.minimumEditedDuration) < 0.001)
        timeline.trimClipStart(at: 0, toEdited: 0.9)
        #expect(timeline.editedDuration >= Clip.minimumEditedDuration - 0.001)
    }

    @Test("Trimming the second clip does not move the first")
    func trimIsPerClip() throws {
        var timeline = whole()
        timeline.split(atEdited: 4)
        let firstDuration = timeline.clips[0].editedDuration
        timeline.trimClipStart(at: 1, toEdited: 6)
        #expect(abs(timeline.clips[0].editedDuration - firstDuration) < 0.001)
        #expect(try abs(#require(timeline.sourceTime(forEdited: 4)) - 6) < 0.001)
    }
}

/// The webcam bubble (docs/09 U3.4).
@Suite("Camera bubble")
struct CameraBubbleTests {
    private let size = CGSize(width: 1920, height: 1080)

    @Test("A bubble sits in the corner it says")
    func placement() {
        var topLeft = CameraBubble.standard
        topLeft.placement = .topLeading
        var bottomRight = CameraBubble.standard
        bottomRight.placement = .bottomTrailing

        let first = topLeft.frame(in: size)
        let second = bottomRight.frame(in: size)
        #expect(first.minX < second.minX)
        #expect(first.minY < second.minY)
    }

    @Test("It stays inside the frame, whatever the corner", arguments: BubblePlacement.allCases)
    func staysInside(placement: BubblePlacement) {
        var bubble = CameraBubble.standard
        bubble.placement = placement
        let frame = bubble.frame(in: size)
        #expect(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(frame))
    }

    /// Normalized so a layout carries between a 1080p and a 4K export.
    @Test("Its size is relative to the frame", arguments: [
        CGSize(width: 1920, height: 1080),
        CGSize(width: 3840, height: 2160)
    ])
    func sizeScales(size: CGSize) {
        let frame = CameraBubble.standard.frame(in: size)
        let shortest = min(size.width, size.height)
        #expect(abs(frame.width - shortest * 0.22) < 0.001)
    }

    @Test("Roundness runs from a rectangle to a circle")
    func roundness() {
        var rectangle = CameraBubble.standard
        rectangle.roundness = 0
        var circle = CameraBubble.standard
        circle.roundness = 1

        #expect(rectangle.cornerRadius(in: size) == 0)
        #expect(abs(circle.cornerRadius(in: size) - circle.frame(in: size).width / 2) < 0.001)
    }

    /// Kept rather than removed, so turning the camera off and on again restores the
    /// layout the user set.
    @Test("Hiding a bubble keeps its layout")
    func hidingKeepsTheLayout() {
        var bubble = CameraBubble(placement: .topLeading, sizeFraction: 0.3)
        bubble.isVisible = false
        #expect(bubble.placement == .topLeading)
        #expect(abs(bubble.sizeFraction - 0.3) < 0.001)
    }

    @Test("Absurd values are clamped into something usable")
    func clamping() {
        let huge = CameraBubble(sizeFraction: 99, marginFraction: 99, roundness: 99)
        #expect(huge.sizeFraction <= 0.6)
        #expect(huge.marginFraction <= 0.2)
        #expect(huge.roundness <= 1)
    }

    @Test("A bubble round-trips")
    func roundTrips() throws {
        let bubble = CameraBubble(placement: .top, sizeFraction: 0.3, roundness: 0.4)
        let data = try JSONEncoder().encode(bubble)
        #expect(try JSONDecoder().decode(CameraBubble.self, from: data) == bubble)
    }

    @Test("A bubble with nothing in it at all decodes to the standard one")
    func emptyObject() throws {
        let bubble = try JSONDecoder().decode(CameraBubble.self, from: Data("{}".utf8))
        #expect(bubble == .standard)
    }

    @Test("A free centre places the bubble there")
    func freeCenter() {
        var bubble = CameraBubble.standard
        bubble.move(toNormalizedCenter: CGPoint(x: 0.5, y: 0.5))
        let frame = bubble.frame(in: size)
        #expect(abs(frame.midX - size.width / 2) < 0.5)
        #expect(abs(frame.midY - size.height / 2) < 0.5)
        #expect(bubble.placement == .centre)
    }

    @Test("A free centre at a corner stays inside the frame")
    func freeCenterStaysInside() {
        var bubble = CameraBubble.standard
        bubble.move(toNormalizedCenter: CGPoint(x: 0, y: 0))
        let frame = bubble.frame(in: size)
        #expect(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(frame))
        #expect(bubble.placement == .topLeading)
    }

    @Test("Resizing from a corner keeps the opposite edge still")
    func resizePinsTheOppositeCorner() {
        var bubble = CameraBubble.standard
        bubble.move(toNormalizedCenter: CGPoint(x: 0.4, y: 0.4))
        let before = bubble.frame(in: size)
        let origin = CGPoint(x: before.minX, y: before.minY)
        bubble.resize(toSizeFraction: 0.35, pinningTopLeading: origin, in: size)
        let after = bubble.frame(in: size)
        #expect(abs(after.minX - before.minX) < 1)
        #expect(abs(after.minY - before.minY) < 1)
        #expect(after.width > before.width)
        #expect(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(after))
    }

    @Test("Snapping to a corner forgets the free position")
    func snapClearsCenter() {
        var bubble = CameraBubble.standard
        bubble.move(toNormalizedCenter: CGPoint(x: 0.4, y: 0.6))
        bubble.snap(to: .bottomTrailing)
        #expect(bubble.center == nil)
        #expect(bubble.placement == .bottomTrailing)
        let snapped = bubble.frame(in: size)
        var corner = CameraBubble.standard
        corner.placement = .bottomTrailing
        #expect(snapped == corner.frame(in: size))
    }

    @Test("A bubble with a free centre round-trips")
    func freeCenterRoundTrips() throws {
        var bubble = CameraBubble.standard
        bubble.move(toNormalizedCenter: CGPoint(x: 0.3, y: 0.7))
        let data = try JSONEncoder().encode(bubble)
        #expect(try JSONDecoder().decode(CameraBubble.self, from: data) == bubble)
    }

    @Test("Fullscreen fills the export")
    func fullscreenFillsTheFrame() {
        #expect(CameraBubble.full.frame(in: size) == CGRect(origin: .zero, size: size))
        var bubble = CameraBubble.standard
        bubble.isFullscreen = true
        #expect(bubble.frame(in: size) == CGRect(origin: .zero, size: size))
    }

    @Test("Dragging a fullscreen bubble returns it to a corner slot")
    func moveLeavesFullscreen() {
        var bubble = CameraBubble.full
        bubble.move(toNormalizedCenter: CGPoint(x: 0.1, y: 0.1))
        #expect(!bubble.isFullscreen)
        #expect(bubble.frame(in: size).width < size.width)
    }

    @Test("An old bubble without the fullscreen flag still opens")
    func fullscreenDefaultsAbsent() throws {
        let json = #"{"placement":"bottomTrailing","sizeFraction":0.22}"#
        let bubble = try JSONDecoder().decode(CameraBubble.self, from: Data(json.utf8))
        #expect(!bubble.isFullscreen)
    }

    // MARK: - Trimming (docs/08 §2 item 12)

    /// Dropping the dead air off the front is the commonest edit anybody makes to a screen
    /// recording, and it was only reachable as split-then-delete-the-first-clip.
    @Test("Trimming the start drops what came before the playhead")
    func trimStartDropsTheHead() {
        var timeline = ClipTimeline.whole(duration: 10)
        timeline.trimStart(toEdited: 3)

        #expect(abs(timeline.editedDuration - 7) < 0.0001)
        // What was at 3 s is now at 0, and the footage it points at is unchanged.
        #expect(abs((timeline.sourceTime(forEdited: 0) ?? -1) - 3) < 0.0001)
    }

    @Test("Trimming the end drops what came after the playhead")
    func trimEndDropsTheTail() {
        var timeline = ClipTimeline.whole(duration: 10)
        timeline.trimEnd(toEdited: 4)

        #expect(abs(timeline.editedDuration - 4) < 0.0001)
        #expect(abs(timeline.sourceTime(forEdited: 0) ?? -1) < 0.0001)
        #expect(timeline.sourceTime(forEdited: 5) == nil, "footage past the trim survived")
    }

    /// A trim at either end asks for something that is already true, or for the recording to
    /// be deleted. Neither is a trim.
    @Test("Trimming to an end of the recording changes nothing", arguments: [0.0, 10.0, -1.0, 99.0])
    func trimAtTheEndsIsANoOp(time: TimeInterval) {
        let original = ClipTimeline.whole(duration: 10)
        var start = original
        start.trimStart(toEdited: time)
        var end = original
        end.trimEnd(toEdited: time)

        #expect(start == original)
        #expect(end == original)
    }

    /// Trimming a timeline that has already been cut keeps the clips on the surviving side,
    /// rather than collapsing them into one.
    @Test("Trimming a cut timeline keeps the clips after the trim")
    func trimKeepsLaterClips() {
        var timeline = ClipTimeline.whole(duration: 12)
        timeline.split(atEdited: 8)
        #expect(timeline.clips.count == 2)

        timeline.trimStart(toEdited: 2)
        #expect(abs(timeline.editedDuration - 10) < 0.0001)
        #expect(timeline.clips.count == 2, "the split at 8s was lost")
    }

    /// Speed survives a trim: a clip playing at 2× that loses its first second is still
    /// playing at 2×.
    @Test("Trimming keeps each clip's speed")
    func trimKeepsSpeed() {
        var timeline = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 10, speed: 2)])
        timeline.trimStart(toEdited: 1)

        #expect(timeline.clips.allSatisfy { $0.speed == 2 })
        #expect(abs(timeline.editedDuration - 4) < 0.0001)
    }

    // MARK: - Cutting a source range

    @Test("Cutting a stretch of the recording leaves the rest")
    func removingSourceRangeKeepsTheSides() {
        let cut = ClipTimeline.whole(duration: 10).removingSourceRange(from: 2, to: 5)
        #expect(cut.clips.count == 2)
        #expect(abs(cut.editedDuration - 7) < 0.0001)
        #expect(cut.containsSourceTime(1))
        #expect(!cut.containsSourceTime(3))
        #expect(cut.containsSourceTime(6))
        #expect(cut.editedTime(forSource: 3) == nil)
        #expect(abs((cut.editedTime(forSource: 6) ?? -1) - 3) < 0.0001)
    }

    @Test("A cut that misses the recording is a no-op")
    func removingAMissDoesNothing() {
        let original = ClipTimeline.whole(duration: 4)
        #expect(original.removingSourceRange(from: 8, to: 9) == original)
        #expect(original.removingSourceRange(from: 2, to: 2) == original)
    }

    @Test("Speed survives a source-range cut")
    func removingSourceRangeKeepsSpeed() {
        let cut = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 10, speed: 2)])
            .removingSourceRange(from: 2, to: 4)
        #expect(cut.clips.allSatisfy { $0.speed == 2 })
        #expect(abs(cut.editedDuration - 4) < 0.0001)
    }
}
