import CoreGraphics
import Foundation
import os
import Shared
import StudioRender
import StudioSession

/// Everything the preview needs to draw a frame, built once per request (docs/10 R1.1).
///
/// Both halves are expensive and neither depends on the playhead. `StudioRenderPlan`
/// integrates a spring at 120 Hz across the whole recording; `StudioFrameComposer`
/// integrates the cursor path again and decodes every cursor PNG. The preview used to build
/// both on the main actor, from inside a view body, on every slider tick — for a ten-minute
/// recording that is around 288,000 spring evaluations per tick, which is why the studio
/// locked up on anything long.
///
/// Now it is built by `build(_:)`, off the main actor, by a player controller that runs one
/// build at a time and keeps showing the last result until the next is ready. What changes
/// while somebody scrubs is only the playhead, and the playhead is an argument to
/// `frame(at:)` — so a scrub costs a decode and never a build.
///
/// Planned at the *preview's* size (`maxLongestEdge`), not the export's: composing a 5K
/// frame to show it in a 1080-pixel well is four times the GPU work for pixels the display
/// throws away. The plan's crop stays in recorded pixels either way, and the compositor
/// hands the composer full-size decoded frames, so the two can never disagree about which
/// part of the recording is being shown.
struct StudioPreviewPipeline: Sendable {
    let plan: StudioRenderPlan
    let composer: StudioFrameComposer

    init(
        edit: StudioEdit,
        manifest: CaptureManifest,
        telemetry: InputTelemetry,
        editedPointer: [PointerSample]? = nil,
        transcript: Transcript = Transcript(),
        wallpaper: CGImage? = nil,
        maxLongestEdge: Int? = nil
    ) {
        plan = StudioRenderPlan(
            edit: edit,
            sourceSize: manifest.pixelSize,
            maxLongestEdge: maxLongestEdge,
            pointer: editedPointer ?? telemetry.rebased(to: edit.clips).pointer
        )
        composer = StudioFrameComposer(
            plan: plan,
            edit: edit,
            // Source time: the composer rebases on its own (docs/10 R0.2).
            telemetry: telemetry,
            transcript: transcript,
            frameRate: manifest.frameRate,
            pointPixelScale: manifest.scale,
            wallpaper: wallpaper
        )
    }

    // MARK: - Building off the main actor

    /// What survives from one build to the next.
    ///
    /// Two things are expensive and change far less often than the edit does: the pointer
    /// path on the edited timeline (rebased by walking every sample, and only different when
    /// the clips are) and the decoded wallpaper. The composer rebases the telemetry for its
    /// own use; its result is kept here so the next plan with the same clips does not do it
    /// a second time.
    struct Reuse: Sendable {
        var pointer: (clips: ClipTimeline, samples: [PointerSample])?
        var wallpaper: (key: WallpaperKey, image: CGImage)?
    }

    /// A wallpaper file as it was when it was decoded. The modification date is part of it
    /// because importing a new picture with the same extension reuses the same file name.
    struct WallpaperKey: Sendable, Equatable {
        let url: URL
        let modified: Date?
    }

    /// Everything a build reads, as `Sendable` values.
    struct Inputs: Sendable {
        let request: StudioPreviewRequest
        let session: RecordingSession
        let manifest: CaptureManifest
        let telemetry: InputTelemetry
        let reuse: Reuse
    }

    private static let signposter = KadrLog.signposter(.app)

    /// Builds a pipeline. Synchronous and CPU-bound: callers run it in a detached task.
    static func build(_ inputs: Inputs) -> (pipeline: StudioPreviewPipeline, reuse: Reuse) {
        let state = signposter.beginInterval("studio.preview.pipelineBuild")
        defer { signposter.endInterval("studio.preview.pipelineBuild", state) }

        let edit = inputs.request.edit
        var reuse = inputs.reuse
        let pointer = reuse.pointer.flatMap { $0.clips == edit.clips ? $0.samples : nil }
        let wallpaper = wallpaper(for: inputs.session.wallpaperURL(for: edit), reuse: &reuse)

        let pipeline = StudioPreviewPipeline(
            edit: edit,
            manifest: inputs.manifest,
            telemetry: inputs.telemetry,
            editedPointer: pointer,
            transcript: inputs.request.transcript,
            wallpaper: wallpaper,
            maxLongestEdge: inputs.request.longestEdge
        )
        reuse.pointer = (edit.clips, pipeline.composer.telemetry.pointer)
        return (pipeline, reuse)
    }

    private static func wallpaper(for url: URL?, reuse: inout Reuse) -> CGImage? {
        guard let url else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let key = WallpaperKey(url: url, modified: modified)
        if let cached = reuse.wallpaper, cached.key == key {
            return cached.image
        }
        guard let image = StudioWallpaper.image(at: url) else { return nil }
        reuse.wallpaper = (key, image)
        return image
    }
}
