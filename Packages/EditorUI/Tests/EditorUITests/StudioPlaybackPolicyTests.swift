import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// The pure decisions behind the studio player (docs/10 R1.1): what size to render at, how
/// much to rebuild, which build runs next and which seek follows which.
@Suite("Studio playback policy")
struct StudioPlaybackPolicyTests {
    // MARK: - Sizes

    @Test(
        "Preview sizes round up to a bucket",
        arguments: [
            (0.0, 1080), (-5.0, 1080), (.infinity, 1080),
            (1.0, 540), (540.0, 540), (541.0, 720), (720.0, 720),
            (1000.0, 1080), (1081.0, 1440), (2000.0, 2160), (2160.0, 2160), (6000.0, 2160)
        ] as [(CGFloat, Int)]
    )
    func sizesRoundUpToABucket(pixels: CGFloat, bucket: Int) {
        #expect(StudioPreviewSize.bucket(forLongestEdge: pixels) == bucket)
    }

    struct ViewSize: Sendable, CustomTestStringConvertible {
        let size: CGSize
        let scale: CGFloat
        let bucket: Int

        var testDescription: String {
            "\(size.width)×\(size.height) @\(scale)x → \(bucket)"
        }
    }

    @Test(
        "The bucket is taken from the longest edge in pixels",
        arguments: [
            ViewSize(size: CGSize(width: 800, height: 450), scale: 2, bucket: 2160),
            ViewSize(size: CGSize(width: 800, height: 450), scale: 1, bucket: 1080),
            ViewSize(size: CGSize(width: 300, height: 700), scale: 2, bucket: 1440),
            ViewSize(size: CGSize(width: 480, height: 270), scale: 1, bucket: 540),
            // A scale below one is a window mid-move between displays; never render smaller
            // than the points being shown.
            ViewSize(size: CGSize(width: 480, height: 270), scale: 0, bucket: 540)
        ]
    )
    func bucketUsesPixels(_ view: ViewSize) {
        #expect(StudioPreviewSize.bucket(for: view.size, backingScale: view.scale) == view.bucket)
    }

    /// A window drag should cost a handful of rebuilds, not one per pixel.
    @Test("Resizing within a bucket changes nothing")
    func resizingWithinABucketIsFree() {
        let buckets = Set(stride(from: 600.0, through: 700.0, by: 1).map {
            StudioPreviewSize.bucket(for: CGSize(width: $0, height: $0 * 0.5625), backingScale: 1)
        })
        #expect(buckets == [720])
    }

    // MARK: - Rebuild policy

    private static let base = StudioPreviewRequest(
        edit: StudioEdit.untouched(duration: 10),
        transcript: nil,
        longestEdge: 1080,
        isCropping: false
    )

    fileprivate static func changed(_ mutate: (inout StudioPreviewRequest) -> Void) -> StudioPreviewRequest {
        var request = base
        mutate(&request)
        return request
    }

    struct RebuildCase: Sendable, CustomTestStringConvertible {
        let name: String
        let request: StudioPreviewRequest
        let expected: StudioPlaybackRebuild

        init(_ name: String, _ expected: StudioPlaybackRebuild, _ mutate: (inout StudioPreviewRequest) -> Void) {
            self.name = name
            self.expected = expected
            request = StudioPlaybackPolicyTests.changed(mutate)
        }

        var testDescription: String {
            name
        }
    }

    static let rebuildCases: [RebuildCase] = [
        RebuildCase("unchanged", .nothing) { _ in },
        RebuildCase("cut", .timeline) {
            $0.edit.clips = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 4)])
        },
        RebuildCase("muted", .timeline) { $0.edit.mutesAudio = true },
        RebuildCase("soundtrack", .timeline) { $0.edit.soundtrackFileName = "soundtrack.wav" },
        RebuildCase("re-imported soundtrack", .timeline) { $0.edit.soundtrackDisplayName = "Take 2" },
        RebuildCase("camera hidden", .timeline) { $0.edit.camera.isVisible.toggle() },
        RebuildCase("zoom", .picture) { $0.edit.zooms = [ZoomCue(start: 1, duration: 2)] },
        RebuildCase("cursor", .picture) { $0.edit.showsCursor.toggle() },
        RebuildCase("mono mix", .picture) { $0.edit.mixesToMono.toggle() },
        RebuildCase("resized", .picture) { $0.longestEdge = 1440 },
        RebuildCase("cropped", .picture) { $0.edit.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5) },
        RebuildCase("captions", .picture) { $0.edit.showsCaptions.toggle() }
    ]

    @Test("Only a timeline change replaces the player item", arguments: rebuildCases)
    func rebuildPolicy(_ rebuild: RebuildCase) {
        #expect(StudioPlaybackRebuild.between(Self.base, rebuild.request) == rebuild.expected)
    }

    @Test("Nothing on screen means building everything")
    func firstRequestBuildsTheTimeline() {
        #expect(StudioPlaybackRebuild.between(nil, Self.base) == .timeline)
    }

    /// Placing a crop shows the whole recording, so the preview edit drops the crop — and
    /// entering crop mode is a picture change, not a new cut.
    @Test("Crop mode previews the uncropped edit")
    func cropModeDropsTheCrop() {
        var edit = StudioEdit.untouched(duration: 10)
        edit.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let cropping = StudioPreviewRequest(edit: edit, transcript: nil, longestEdge: 1080, isCropping: true)
        let showing = StudioPreviewRequest(edit: edit, transcript: nil, longestEdge: 1080, isCropping: false)
        #expect(cropping.edit.cropRect == nil)
        #expect(showing.edit.cropRect == edit.cropRect)
        #expect(StudioPlaybackRebuild.between(showing, cropping) == .picture)
    }

    // MARK: - Latest wins

    @Test("An idle queue starts a request at once")
    func idleStartsImmediately() {
        var queue = StudioLatestWins<Int>()
        #expect(queue.isIdle)
        #expect(queue.submit(1) == 1)
        #expect(queue.running == 1)
        #expect(queue.finish() == nil)
        #expect(queue.isIdle)
    }

    @Test("A burst while building collapses to its last request")
    func burstCollapses() {
        var queue = StudioLatestWins<Int>()
        #expect(queue.submit(1) == 1)
        for value in 2 ... 40 {
            #expect(queue.submit(value) == nil, "\(value) started while 1 was running")
        }
        #expect(queue.queued == 40)
        #expect(queue.finish() == 40)
        #expect(queue.finish() == nil)
        #expect(queue.isIdle)
    }

    /// Dragging a slider away and back to where the running build started does not need a
    /// second build of the same thing.
    @Test("Returning to the running request drops the queued one")
    func returningToRunningDropsQueue() {
        var queue = StudioLatestWins<Int>()
        _ = queue.submit(1)
        _ = queue.submit(2)
        #expect(queue.submit(1) == nil)
        #expect(queue.queued == nil)
        #expect(queue.finish() == nil)
    }

    @Test("Reset forgets everything")
    func resetForgets() {
        var queue = StudioLatestWins<Int>()
        _ = queue.submit(1)
        _ = queue.submit(2)
        queue.reset()
        #expect(queue.isIdle)
        #expect(queue.submit(3) == 3)
    }

    // MARK: - Seek chase

    @Test("A scrub issues one seek and chases the latest target")
    func chaseIssuesOneSeekAtATime() {
        var chase = StudioSeekChase()
        #expect(chase.request(1) == 1)
        #expect(chase.request(2) == nil)
        #expect(chase.request(3) == nil)
        #expect(chase.pending == 3)
        #expect(chase.completed() == 3)
        #expect(chase.inFlight == 3)
        #expect(chase.completed() == nil)
        #expect(chase == StudioSeekChase())
    }

    @Test("A scrub that ends where the seek landed issues nothing more")
    func chaseSkipsTheSameTarget() {
        var chase = StudioSeekChase()
        _ = chase.request(5)
        _ = chase.request(6)
        _ = chase.request(5)
        #expect(chase.completed() == nil)
        #expect(chase.inFlight == nil)
    }

    @Test("A reset chase accepts a new seek at once")
    func resetChaseAcceptsASeek() {
        var chase = StudioSeekChase()
        _ = chase.request(1)
        _ = chase.request(2)
        chase.reset()
        #expect(chase.request(4) == 4)
    }
}
