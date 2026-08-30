import Foundation
import StudioRender
import StudioSession

/// Everything the preview needs to draw a frame, built once per edit (docs/10 R1.1).
///
/// Both halves are expensive and neither depends on the playhead. `StudioRenderPlan`
/// integrates a spring at 120 Hz across the whole recording; `StudioFrameComposer`
/// integrates the cursor path again and decodes every cursor PNG. The preview used to build
/// both on every scrub event — for a ten-minute recording that is around 288,000 spring
/// evaluations and several megabytes of allocation per mouse-move, on the main actor, which
/// is why the timeline locked up on anything long.
///
/// What actually changes while somebody scrubs is the playhead, and the playhead is an
/// argument to `frame(at:)`. So this is keyed on the edit, and a scrub costs one decode.
struct StudioPreviewPipeline {
    let plan: StudioRenderPlan
    let composer: StudioFrameComposer
    /// The edit this was built for, which is the whole cache key.
    private let edit: StudioEdit

    init(edit: StudioEdit, manifest: CaptureManifest, telemetry: InputTelemetry) {
        self.edit = edit
        plan = StudioRenderPlan(edit: edit, sourceSize: manifest.pixelSize)
        composer = StudioFrameComposer(
            plan: plan,
            edit: edit,
            telemetry: telemetry,
            frameRate: manifest.frameRate
        )
    }

    /// Whether this pipeline still describes the edit being shown.
    ///
    /// `StudioEdit` is `Hashable` and compared whole rather than by the fields that happen
    /// to matter today. A cache key that lists what it cares about is a cache key that goes
    /// stale the moment somebody adds a field — silently, and only in the preview.
    func matches(_ edit: StudioEdit) -> Bool {
        self.edit == edit
    }
}
