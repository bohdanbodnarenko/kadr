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
        guard clips.isEdited else { return self }

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

public extension ClipTimeline {
    /// Whether this timeline changes the footage at all.
    ///
    /// One clip at natural speed covering the recording from the start is a timeline that
    /// converts source time to itself, so everything that would rebase against it can skip
    /// the work — which is most recordings, most of the time.
    var isEdited: Bool {
        guard clips.count == 1, let only = clips.first else { return true }
        return only.sourceStart != 0 || only.speed != 1
    }
}
