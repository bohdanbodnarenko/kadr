import AVFoundation
import CoreImage
import Foundation
import StudioRender
import StudioSession
import SwiftUI

/// The studio's picture (docs/09 U3.3).
///
/// Frames come from the same `StudioFrameComposer` the export uses, over the same
/// `StudioRenderPlan`. That is the entire reason the preview can be trusted: it is not
/// approximating what the export will do, it is doing it, one frame at a time and at
/// whatever size the window happens to be.
///
/// Scrubbed *and* played (docs/08 §2 item 10). Most of a studio edit is made one moment at a
/// time, which is why this decodes on demand rather than running a player at 60 fps for a
/// session spent mostly paused — but a zoom is a movement, a cut is a join and a speed change
/// is a rhythm, and none of the three can be judged from a frozen frame. `.task(id:)` gives
/// playback its frame-dropping for free: a playhead that moves before the last decode
/// finished cancels it, so a slow machine plays a coarser preview rather than falling behind.
@MainActor
struct StudioPreviewView: View {
    let model: StudioDocumentModel

    @State private var frame: CGImage?
    @State private var renderer: StudioPreviewRenderer?
    /// The plan and the composer, rebuilt only when the edit changes (docs/10 R1.1).
    @State private var pipeline: StudioPreviewPipeline?

    var body: some View {
        GeometryReader { geometry in
            let fitted = StudioCropGeometry.fittedImageRect(
                image: previewImageSize,
                in: geometry.size
            )
            ZStack {
                // A recessed well rather than a black rectangle butted against the window
                // edge: the picture is the thing being judged, and a surround that reads as
                // a surface tells the eye where it stops.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                if model.isCropping {
                    StudioCropOverlay(model: model, fitted: fitted)
                } else if model.manifest.hasCamera, model.edit.camera.isVisible {
                    StudioCameraOverlay(
                        model: model,
                        fitted: fitted,
                        imageSize: previewImageSize
                    )
                }
            }
            // Deliberately not crossfaded between frames. A fade needs a view-identity
            // change to animate across, and forcing one thirty times a second during
            // playback would have SwiftUI tear down and rebuild the image for every frame —
            // paying for a flourish nobody can see at that rate with the smoothness of the
            // playback itself.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .padding(10)
        }
        .task {
            renderer = StudioPreviewRenderer(
                session: model.session,
                cameraStartOffset: model.manifest.cameraStartOffset
            )
            await refresh()
        }
        // Two triggers, because they cost different amounts. A scrub reuses the pipeline
        // and costs one decode; an edit rebuilds it. Watching the whole model instead would
        // redraw on the selection changing, which costs a decode and changes nothing.
        // Hover-skim is a third: it must not move the playhead, but it must show the frame
        // under the pointer. Quantised so a fast sweep does not decode every pixel.
        .task(id: model.playhead) {
            guard model.skimTime == nil else { return }
            await refresh()
        }
        .task(id: skimKey) { await refresh() }
        .task(id: model.edit) { await refresh() }
        .task(id: model.isCropping) { await refresh() }
    }

    /// The uncropped recording while a crop is being placed, so the overlay can grow.
    private var previewEdit: StudioEdit {
        guard model.isCropping else { return model.edit }
        var edit = model.edit
        edit.cropRect = nil
        return edit
    }

    private var previewImageSize: CGSize {
        model.isCropping ? model.manifest.pixelSize : currentPipeline().plan.outputSize
    }

    private var previewTime: TimeInterval {
        model.skimTime ?? model.playhead
    }

    /// Fifteen keys a second while skimming. Enough to follow a hover without decoding
    /// every pointer-moved event. −1 when not skimming, so the playhead task owns that path.
    private var skimKey: Int {
        guard let skim = model.skimTime else { return -1 }
        return Int((skim * 15).rounded())
    }

    private func refresh() async {
        guard let renderer else { return }
        frame = await renderer.image(
            at: previewTime,
            using: currentPipeline().composer,
            exact: !model.isPlaying && model.skimTime == nil
        )
    }

    /// The pipeline for the edit on screen, rebuilt only when that edit changes.
    private func currentPipeline() -> StudioPreviewPipeline {
        let edit = previewEdit
        if let pipeline, pipeline.matches(edit, transcript: model.transcript) {
            return pipeline
        }
        let built = StudioPreviewPipeline(
            edit: edit,
            manifest: model.manifest,
            telemetry: model.telemetry,
            transcript: model.transcript ?? Transcript(),
            wallpaper: model.session.wallpaperURL(for: edit).flatMap { StudioWallpaper.image(at: $0) }
        )
        pipeline = built
        return built
    }
}

/// Decodes one frame of a session and composes it (docs/09 U3.3).
///
/// An actor because decoding is the slow part and it must not happen on the main actor: a
/// preview that blocks while it seeks makes the timeline feel broken, which is worse than
/// a preview that lags a frame behind the scrub.
actor StudioPreviewRenderer {
    private let generator: AVAssetImageGenerator?
    private let cameraGenerator: AVAssetImageGenerator?

    /// How far into the recording the camera's first frame landed (docs/11 S0.5).
    ///
    /// Camera time zero is screen time `cameraStartOffset`, and the export has shifted by it
    /// since R0.5 — but the preview seeked the raw `camera.mov` at the screen's own source
    /// time, so the bubble ran ahead of the picture by however long the capture session took
    /// to wake up: a third of a second on a built-in camera, over a second on some external
    /// ones. Somebody lining the bubble up against the preview was lining it up against
    /// something the export does not produce, which makes a liar of the three separate doc
    /// comments in this file asserting that the preview *is* the export.
    private let cameraStartOffset: TimeInterval

    init(session: RecordingSession, cameraStartOffset: TimeInterval) {
        self.cameraStartOffset = cameraStartOffset
        generator = Self.makeGenerator(for: session.screenURL)
        cameraGenerator = Self.makeGenerator(for: session.cameraURL)
    }

    private static func makeGenerator(for url: URL) -> AVAssetImageGenerator? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // Zero tolerance: the studio's whole claim is that the preview is the export, and a
        // generator allowed to return a nearby keyframe would show a different frame than
        // the one being rendered. The seek costs more; being right is the feature.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    /// The composed frame at an edited-time instant.
    ///
    /// The composer is passed in rather than built here: it carries the spring integration
    /// and the decoded cursor artwork, neither of which depends on the playhead, and
    /// building one per scrub is what made a long timeline unusable (docs/10 R1.1).
    /// - Parameter exact: false while playing, which lets the generator return the nearest
    ///   frame within a tenth of a second instead of decoding to the precise one. A
    ///   zero-tolerance seek costs a full decode from the previous keyframe, and thirty of
    ///   those a second is not a rate any Mac sustains — so insisting on exactness during
    ///   playback does not buy a truthful preview, it buys a slideshow. Paused, it is exact
    ///   again, which is where "the preview is the export" is actually being relied on.
    func image(
        at time: TimeInterval,
        using composer: StudioFrameComposer,
        exact: Bool = true
    ) async -> CGImage? {
        guard generator != nil else { return nil }
        setTolerance(exact: exact)
        let edit = composer.edit
        // Edited time is not source time once anything has been cut or sped up, and asking
        // the generator for the wrong one shows the frame from before the edit. A playhead
        // past the end has no source frame at all, which is a blank preview rather than a
        // failure — it is where the recording stopped.
        guard let source = edit.clips.sourceTime(forEdited: time),
              let screen = await copyScreen(at: source)
        else {
            return nil
        }

        var camera: CIImage?
        if edit.camera.isVisible {
            camera = await copyCamera(at: source - cameraStartOffset).map(CIImage.init(cgImage:))
        }
        let composed = composer.frame(at: time, source: CIImage(cgImage: screen), camera: camera)
        return StudioRenderContext.shared.createCGImage(composed, from: composed.extent)
    }

    /// How close to the requested instant a returned frame has to be.
    private func setTolerance(exact: Bool) {
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        for generator in [generator, cameraGenerator].compactMap(\.self) {
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
        }
    }

    /// One frame of the screen recording.
    ///
    /// The two generators are read through their own methods rather than one taking a
    /// generator as an argument: `AVAssetImageGenerator` is not `Sendable`, and handing one
    /// across a call is a data race the compiler is right to refuse. Held here, each stays
    /// inside the actor that owns it.
    private func copyScreen(at seconds: TimeInterval) async -> CGImage? {
        guard let generator else { return nil }
        return await Self.copy(from: Generator(generator), at: seconds)
    }

    private func copyCamera(at seconds: TimeInterval) async -> CGImage? {
        guard let cameraGenerator else { return nil }
        // Before the camera woke up there is no frame to show, and clamping to zero would
        // hold its first frame over the opening of the recording — which is exactly the
        // still, staring bubble the offset exists to avoid. The export leaves this stretch
        // empty; so does this.
        guard seconds >= 0 else { return nil }
        return await Self.copy(from: Generator(cameraGenerator), at: seconds)
    }

    private static func copy(from boxed: Generator, at seconds: TimeInterval) async -> CGImage? {
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        return try? await boxed.generator.image(at: time).image
    }

    /// Carries a generator into its own async call.
    ///
    /// `AVAssetImageGenerator` is not `Sendable` and its async `image(at:)` is nonisolated,
    /// so awaiting it hands the generator out of the actor — which the compiler is right to
    /// refuse in general. It is safe here for the reason the box documents: this actor is
    /// the only owner, one generator is only ever read by one call at a time, and the
    /// generator is itself documented as safe to use concurrently (docs/04 §8).
    private struct Generator: @unchecked Sendable {
        let generator: AVAssetImageGenerator

        init(_ generator: AVAssetImageGenerator) {
            self.generator = generator
        }
    }
}
