import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import os
import Shared

/// What the studio's compositor is asked to do for one stretch of the timeline.
///
/// One instruction spans the whole edit. Everything that varies over time — the zoom, the
/// cursor, the captions — is already a function of the playhead inside the composer, so
/// splitting the timeline into instructions would only give AVFoundation more boundaries
/// to stall at.
///
/// `Sendable` for real rather than by assertion: every stored property is an immutable
/// value, and AVFoundation reads instructions from its own threads.
final class StudioVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// True: every frame is different from its source even when the source did not move,
    /// because the cursor and the camera are drawn from telemetry, not from the pixels.
    let containsTweening = true
    /// Built on demand rather than stored: `NSValue` is not `Sendable`, the track IDs are.
    var requiredSourceTrackIDs: [NSValue]? {
        ([screenTrackID] + [cameraTrackID].compactMap(\.self)).map { NSNumber(value: $0) }
    }

    let passthroughTrackID = kCMPersistentTrackID_Invalid

    /// The export's own frame builder, so the picture being played is the picture being
    /// written (docs/09 U3.3).
    let composer: StudioFrameComposer
    let screenTrackID: CMPersistentTrackID
    /// The webcam's track, when the composition carries one.
    let cameraTrackID: CMPersistentTrackID?

    init(
        timeRange: CMTimeRange,
        composer: StudioFrameComposer,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?
    ) {
        self.timeRange = timeRange
        self.composer = composer
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        super.init()
    }
}

/// Composes studio frames inside AVFoundation's own pipeline (docs/09 U3.3, docs/10 R1.1).
///
/// The preview used to decode each frame with a seeking image generator, compose it, read
/// the whole thing back off the GPU into a `CGImage` and hand that to SwiftUI — around 59 MB
/// of copying per 5K frame, thirty times a second, on a clock of its own that the audio had
/// to be dragged along behind. A custom compositor inverts that: `AVPlayer` decodes in
/// order, asks for a frame when the display needs one, and shows the result straight from
/// an IOSurface. Nothing is read back, the audio and the picture share one clock, and
/// frames are dropped by the player that knows when they are late.
///
/// The export still writes with a reader/writer pass (it has to report progress), but both
/// paths call the same `StudioFrameComposer.frame(at:source:camera:)`, which is what keeps
/// "the preview is the export" true.
///
/// `@unchecked Sendable` because `AVVideoCompositing` is an Objective-C protocol AVFoundation
/// calls from its own threads and Swift cannot check that. The invariant that makes it
/// safe: this class has no mutable state at all. Every request is finished before
/// `startRequest(_:)` returns, and everything a request needs travels in its instruction,
/// which is itself `Sendable`.
final class StudioVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let signposter = KadrLog.signposter(.app)
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// The pixel format CoreImage works in natively, backed by IOSurface so the decoded
    /// frame reaches the GPU without a copy.
    static let pixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = StudioVideoCompositor.pixelBufferAttributes
    // swiftlint:disable:next identifier_name
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        StudioVideoCompositor.pixelBufferAttributes

    enum CompositionError: Error {
        case unexpectedInstruction
        case missingSourceFrame
        case noOutputBuffer
    }

    /// Nothing to keep: every request reads its own render context.
    func renderContextChanged(_: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let state = Self.signposter.beginInterval("studio.preview.compose")
        defer { Self.signposter.endInterval("studio.preview.compose", state) }

        guard let instruction = request.videoCompositionInstruction as? StudioVideoCompositionInstruction else {
            request.finish(with: CompositionError.unexpectedInstruction)
            return
        }
        guard let screen = request.sourceFrame(byTrackID: instruction.screenTrackID) else {
            request.finish(with: CompositionError.missingSourceFrame)
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CompositionError.noOutputBuffer)
            return
        }
        // Nil before the camera woke up, which is exactly what the export draws there: no
        // bubble, rather than its first frame held over the opening.
        let camera = instruction.cameraTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map { CIImage(cvPixelBuffer: $0) }

        // The composition is already on the edited timeline, so its clock is the playhead.
        let time = max(CMTimeGetSeconds(request.compositionTime), 0)
        let composed = instruction.composer.frame(
            at: time.isFinite ? time : 0,
            source: CIImage(cvPixelBuffer: screen),
            camera: camera
        )
        render(composed, planned: instruction.composer.plan.outputSize, into: output)
        request.finish(withComposedVideoFrame: output)
    }

    /// Every request is finished inside `startRequest(_:)`, so by the time AVFoundation
    /// asks there is nothing pending to cancel — which is the contract's "or finished
    /// processing of all the frames" branch, met without a queue of our own.
    func cancelAllPendingVideoCompositionRequests() {}

    /// Renders into the buffer the render context vended.
    ///
    /// Scaled when the two disagree: an image generator given a `maximumSize` shrinks the
    /// render context rather than the composition, and a frame drawn at the planned size
    /// into a smaller buffer would show only its bottom-left corner.
    private func render(_ image: CIImage, planned: CGSize, into buffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var fitted = image
        if planned.width > 0, planned.height > 0, size != planned {
            fitted = image.transformed(by: CGAffineTransform(
                scaleX: size.width / planned.width,
                y: size.height / planned.height
            ))
        }
        StudioRenderContext.shared.render(
            fitted,
            to: buffer,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: Self.colorSpace
        )
        if let colorSpace = Self.colorSpace {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        }
    }
}

/// The studio's frames as an `AVVideoComposition`, for a player or an image generator
/// (docs/09 U3.3).
///
/// The only public door to `StudioVideoCompositor`: callers hand over a composition and a
/// composer and get back something AVFoundation will play, and never touch the
/// compositor or its instructions directly.
public enum StudioVideoComposition {
    /// A video composition that draws `composer`'s frames over `composition`.
    ///
    /// The screen is the first video track and the camera, when there is one, the second —
    /// the order `ClipCompositionBuilder` appends them in.
    /// - Parameter frameRate: the recording's own rate; asking for more only composes the
    ///   same decoded frame twice.
    public static func make(
        for composition: AVComposition,
        composer: StudioFrameComposer,
        frameRate: Int
    ) -> AVMutableVideoComposition? {
        let tracks = composition.tracks(withMediaType: .video)
        guard let screen = tracks.first else { return nil }
        let size = composer.plan.outputSize
        guard size.width >= 1, size.height >= 1 else { return nil }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = StudioVideoCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
        video.renderSize = CGSize(width: size.width.rounded(), height: size.height.rounded())
        video.instructions = [
            StudioVideoCompositionInstruction(
                timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                composer: composer,
                screenTrackID: screen.trackID,
                cameraTrackID: tracks.count > 1 ? tracks[1].trackID : nil
            )
        ]
        return video
    }
}
