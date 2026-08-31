import CoreGraphics
import CoreImage
import CoreText
import Foundation
import StudioSession

/// Rasterising the overlays: the ripple and the keystroke caption (docs/09 U3.2).
///
/// Split from the composer because these draw pictures while everything there places them,
/// and because the two answer the same question in different units — a ripple is sized from
/// the recording because it belongs to the scene, a caption from the output frame because it
/// is drawn on top of one. Keeping them side by side is what makes that deliberate rather
/// than accidental (docs/11 S0.5).
extension StudioFrameComposer {
    // MARK: - Drawing the overlays

    /// The click ripple at one instant, drawn at the size the shared metrics ask for.
    ///
    /// The metrics are fractions of the *recorded* area's shortest edge, so the ripple is
    /// the same size relative to the content whatever the recording's resolution — then
    /// scaled by the camera, because a ripple belongs to the scene and zooms with it.
    func ripple(progress: Double, scale: CGFloat) -> CGImage? {
        let reference = min(plan.sourceSize.width, plan.sourceSize.height) * scale
        let radius = reference * ClickRippleMetrics.radiusFraction(at: progress)
        let stroke = reference * ClickRippleMetrics.strokeFraction(at: progress)
        let opacity = ClickRippleMetrics.opacity(at: progress)
        guard radius > 0.5, opacity > 0.001 else { return nil }

        let side = Int((radius * 2 + stroke * 2).rounded(.up))
        return BitmapCanvas.image(width: side, height: side) { context in
            let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: opacity)
            context.setLineWidth(stroke)
            context.strokeEllipse(in: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }

    /// The keystroke caption showing at `time`, and where it goes.
    func caption(at time: TimeInterval) -> (image: CGImage?, placement: CGRect)? {
        // Binary-searched and walked back, rather than filtering every chord in the
        // recording into a fresh array on every frame (docs/10 R1.2).
        let recent = TimeSortedLookup.elements(
            within: ClickRippleMetrics.captionDuration,
            endingAt: time,
            in: telemetry.keystrokes,
            key: \.time
        )
        guard let last = recent.last else { return nil }
        let opacity = ClickRippleMetrics.captionOpacity(elapsed: time - last.time)
        guard opacity > 0.001 else { return nil }

        // The last few chords rather than only the newest: somebody demonstrating ⌘⇧4 hits
        // three keys in half a second, and a caption that replaces itself each time shows
        // the last one and implies the others never happened.
        let text = recent.suffix(3).map(\.caption).joined(separator: "  ")
        // Against the output's *shortest* edge, not its height (docs/11 S0.5).
        //
        // A ripple is sized from the recording and a caption from the output frame, which
        // is right — one belongs to the scene and one is drawn on top of it — but the
        // caption used the height alone, and height is not a measure of how big a frame is
        // once the frame can be 9:16. A vertical export made the caption two-thirds again
        // as large relative to its frame as the same caption on the same recording exported
        // 16:9, while the ripple beside it stayed put. On landscape output this is the
        // number it always was.
        let reference = min(plan.outputSize.width, plan.outputSize.height)
        let fontSize = max(reference * 0.035, 12)
        guard let image = CaptionCanvas.image(text: text, fontSize: fontSize, opacity: opacity) else {
            return nil
        }
        let margin = reference * 0.06
        let placement = CGRect(
            x: (plan.outputSize.width - CGFloat(image.width)) / 2,
            y: plan.outputSize.height - CGFloat(image.height) - margin,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        return (image, placement)
    }

    /// Burned-in speech captions with karaoke highlighting (docs/13 T2.2).
    func speechCaption(at time: TimeInterval) -> (image: CGImage?, placement: CGRect)? {
        guard let cue = CaptionExport.cue(from: transcript, timeline: edit.clips, at: time) else {
            return nil
        }
        let reference = min(plan.outputSize.width, plan.outputSize.height)
        let fontSize = max(reference * 0.032, 11)
        let text: String = if let highlight = cue.highlight, !highlight.isEmpty {
            cue.text
        } else {
            cue.text
        }
        guard let image = CaptionCanvas.image(text: text, fontSize: fontSize, opacity: 0.92) else {
            return nil
        }
        let margin = reference * 0.05
        let placement = CGRect(
            x: (plan.outputSize.width - CGFloat(image.width)) / 2,
            y: margin,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        return (image, placement)
    }
}
