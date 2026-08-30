import CoreGraphics
import Foundation

/// Moving telemetry from the recording's clock onto the edit's (docs/10 R0.2).
///
/// The sidecar is written in **source time** — where things happened in the footage. The
/// studio plays, scrubs and renders in **edited time** — where things happen after the cuts
/// and the speed changes. The two are the same number only for an untouched recording,
/// which is exactly why the mistake survives: every test on a whole recording passes, and
/// the error appears the first time somebody cuts something.
///
/// `ClipTimeline` documents itself as "the one place that converts between them" and three
/// consumers never called it. Cut ten seconds from the middle and every click ripple and
/// keystroke caption after the cut fired against the wrong footage; set a clip to 2× and
/// the cursor played at half the picture's speed.
///
/// Converting once, here, is what makes that unrepresentable downstream: past this point
/// there is only edited time, and the preview and the export share it by construction
/// rather than by both remembering to do the same thing.
public extension InputTelemetry {
    /// This telemetry with every timestamp moved onto the edited timeline.
    ///
    /// Events inside a cut are dropped rather than clamped to its edges. A click that
    /// happened in footage the user removed did not happen in the edit — piling those
    /// against the cut point would put a burst of ripples exactly where the join is, which
    /// is the one moment the eye is already watching.
    func rebased(to clips: ClipTimeline) -> InputTelemetry {
        // An untouched recording maps one-to-one, and the common case should cost nothing.
        // Measured against the telemetry's own extent, which is the only length available
        // here — and the right one: what matters is whether anything recorded falls outside
        // what the timeline keeps.
        guard clips.isEdited(ofRecordingLasting: latestEventTime) else { return self }

        var rebased = self
        rebased.pointer = pointer.compactMap { sample in
            clips.editedTime(forSource: sample.time).map { time in
                PointerSample(time: time, position: sample.position, cursorIndex: sample.cursorIndex)
            }
        }
        rebased.clicks = clicks.compactMap { click in
            clips.editedTime(forSource: click.time).map { time in
                ClickEvent(time: time, position: click.position, button: click.button, isDown: click.isDown)
            }
        }
        rebased.keystrokes = keystrokes.compactMap { keystroke in
            clips.editedTime(forSource: keystroke.time).map { time in
                KeystrokeEvent(time: time, caption: keystroke.caption)
            }
        }
        rebased.windowGeometry = windowGeometry.compactMap { sample in
            clips.editedTime(forSource: sample.time).map { time in
                WindowGeometrySample(time: time, frame: sample.frame)
            }
        }
        return rebased
    }
}

public extension InputTelemetry {
    /// The last instant anything was recorded at.
    ///
    /// Stands in for the recording's length where the manifest is not to hand. It is a lower
    /// bound rather than the exact duration, which is the safe direction: it can only make
    /// `rebased(to:)` take the slow path when the fast one would have done, never the other
    /// way round.
    var latestEventTime: TimeInterval {
        max(
            pointer.last?.time ?? 0,
            clicks.last?.time ?? 0,
            keystrokes.last?.time ?? 0,
            windowGeometry.last?.time ?? 0
        )
    }
}

public extension ClipTimeline {
    /// Where the last surviving frame sits in the recording.
    var sourceEnd: TimeInterval {
        clips.reduce(0) { max($0, $1.sourceStart + $1.sourceDuration) }
    }

    /// Whether this timeline changes a recording of `duration` at all.
    ///
    /// One clip at natural speed, starting at zero and running to the end, converts source
    /// time to itself — so everything that would rebase against it can skip the work, which
    /// is most recordings most of the time.
    ///
    /// The length is a parameter because a timeline cannot answer without it, and the
    /// version that tried to was wrong (docs/11 S2). It asked only whether the clip started
    /// late or ran at a different speed, so a recording trimmed at the *end* — one clip,
    /// starting at zero, natural speed, just shorter — reported itself unedited. Telemetry
    /// then took the fast path and kept every click and keystroke from the part the user had
    /// cut off, which the export duly drew over footage that no longer exists. Trimming the
    /// end is not an exotic edit; it is the most common one there is.
    func isEdited(ofRecordingLasting duration: TimeInterval) -> Bool {
        guard clips.count == 1, let only = clips.first else { return true }
        guard only.sourceStart == 0, only.speed == 1 else { return true }
        // A frame's worth of slack at 60 fps: a timeline built from a duration that went
        // through a `CMTime` and back is not bit-identical to the one it started as, and
        // rebasing a whole recording because of a rounding error is a real cost.
        return only.sourceDuration < duration - 0.017
    }
}
