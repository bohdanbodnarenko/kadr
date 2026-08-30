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
}
