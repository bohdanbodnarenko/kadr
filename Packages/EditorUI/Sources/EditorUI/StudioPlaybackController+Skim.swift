import AVFoundation
import CoreGraphics
import Foundation
import StudioRender
import StudioSession

/// The timeline hover thumbnail (docs/16 STU-C5).
extension StudioPlaybackController {
    /// Shows a thumbnail for a timeline hover, or clears it.
    ///
    /// Its own generator on the same composition, with its own small plan — a thumbnail
    /// 160 points wide composed at the preview's size would be most of a frame's work for
    /// a sixteenth of its pixels. Latest-wins: a new hover cancels the last, and a
    /// cancelled request never clears a picture that is still correct enough to show.
    func skim(at time: TimeInterval?) {
        skimTask?.cancel()
        skimTask = nil
        guard let time, let model, !model.isPlaying,
              let request = installed, let composition
        else {
            skimGenerator?.generator.cancelAllCGImageGeneration()
            skimImage = nil
            return
        }
        let small = request.resized(to: StudioPreviewSize.skimLongestEdge)
        let pipeline = skimPipeline(for: small, model: model)
        let frameRate = model.manifest.frameRate

        skimTask = Task { [weak self] in
            let built = await pipeline.value
            guard let self, !Task.isCancelled else { return }
            guard let generator = generator(for: composition, request: small, pipeline: built, frameRate: frameRate)
            else { return }
            generator.generator.cancelAllCGImageGeneration()
            let image = await generator.image(at: Self.time(time))
            guard !Task.isCancelled, let image else { return }
            skimImage = image
        }
    }

    private func skimPipeline(
        for request: StudioPreviewRequest,
        model: StudioDocumentModel
    ) -> Task<StudioPreviewPipeline, Never> {
        if let skimBuild, skimBuild.request == request {
            return skimBuild.task
        }
        let inputs = StudioPreviewPipeline.Inputs(
            request: request,
            session: model.session,
            manifest: model.manifest,
            telemetry: model.telemetry,
            reuse: reuse
        )
        let task = Task.detached(priority: .utility) {
            StudioPreviewPipeline.build(inputs).pipeline
        }
        skimBuild = (request, task)
        return task
    }

    private func generator(
        for composition: AVComposition,
        request: StudioPreviewRequest,
        pipeline: StudioPreviewPipeline,
        frameRate: Int
    ) -> StudioPlaybackSkimGenerator? {
        if let skimGenerator, skimGenerator.composition === composition, skimGenerator.request == request {
            return skimGenerator
        }
        guard let video = StudioVideoComposition.make(
            for: composition,
            composer: pipeline.composer,
            frameRate: frameRate
        ) else { return nil }
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = video
        let edge = CGFloat(StudioPreviewSize.skimLongestEdge)
        generator.maximumSize = CGSize(width: edge, height: edge)
        // A tenth of a second of slack: a thumbnail that tracks the pointer beats one that
        // is frame-exact and a decode behind.
        let tolerance = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let boxed = StudioPlaybackSkimGenerator(generator: generator, composition: composition, request: request)
        skimGenerator = boxed
        return boxed
    }
}

/// Carries the skim generator into its own async call.
///
/// `AVAssetImageGenerator` is not `Sendable` and its async `image(at:)` is nonisolated,
/// so awaiting it hands the generator off the main actor. Safe for the reason the box
/// states: the controller is the only owner, it only ever configures the generator
/// before the first request, and the generator is documented as safe to call
/// concurrently (docs/04 §8). The composition is immutable.
final class StudioPlaybackSkimGenerator: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    let composition: AVComposition
    let request: StudioPreviewRequest

    init(generator: AVAssetImageGenerator, composition: AVComposition, request: StudioPreviewRequest) {
        self.generator = generator
        self.composition = composition
        self.request = request
    }

    nonisolated func image(at time: CMTime) async -> CGImage? {
        try? await generator.image(at: time).image
    }
}
