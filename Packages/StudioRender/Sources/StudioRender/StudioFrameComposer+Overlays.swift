import CoreGraphics
import CoreImage
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
        let drawn = min(
            max(edit.clickScale, StudioEdit.minimumCursorScale),
            StudioEdit.maximumCursorScale
        )
        let radius = reference * ClickRippleMetrics.radiusFraction(at: progress) * drawn
        let stroke = reference * ClickRippleMetrics.strokeFraction(at: progress) * drawn
        let opacity = ClickRippleMetrics.opacity(at: progress)
        guard radius > 0.5, opacity > 0.001 else { return nil }

        let side = Int((radius * 2 + stroke * 2).rounded(.up))
        return BitmapCanvas.image(width: side, height: side) { context in
            let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
            let rect = CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            switch edit.clickStyle {
            case .filled:
                context.setFillColor(
                    red: edit.clickColor.red,
                    green: edit.clickColor.green,
                    blue: edit.clickColor.blue,
                    alpha: opacity
                )
                context.fillEllipse(in: rect)
            case .outline:
                context.setStrokeColor(
                    red: edit.clickColor.red,
                    green: edit.clickColor.green,
                    blue: edit.clickColor.blue,
                    alpha: opacity
                )
                context.setLineWidth(stroke)
                context.strokeEllipse(in: rect)
            }
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
        // Against the card's *shortest* edge, not the padded canvas (docs/11 S0.5).
        //
        // A ripple is sized from the recording and a caption from the output frame, which
        // is right — one belongs to the scene and one is drawn on top of it — but the
        // caption used the height alone, and height is not a measure of how big a frame is
        // once the frame can be 9:16. A vertical export made the caption two-thirds again
        // as large relative to its frame as the same caption on the same recording exported
        // 16:9, while the ripple beside it stayed put. On landscape output this is the
        // number it always was. After a Presenter canvas the card is the frame that matters.
        let reference = min(plan.cardRect.width, plan.cardRect.height)
        let fontSize = max(reference * 0.035 * edit.keystrokeScale, 12)
        guard let image = CaptionCanvas.image(
            text: text,
            fontSize: fontSize,
            opacity: opacity,
            appearance: edit.keystrokeAppearance
        ) else {
            return nil
        }
        return (image, overlayFrame(for: image, placing: edit.keystrokePlacement, marginFraction: 0.06))
    }

    /// Burned-in speech captions with karaoke highlighting (docs/13 T2.2).
    func speechCaption(at time: TimeInterval) -> (image: CGImage?, placement: CGRect)? {
        guard var cue = CaptionExport.cue(in: captionCues, at: time) else {
            return nil
        }
        if edit.highlightsSpokenWord {
            cue = CaptionExport.highlighting(cue, from: transcript, timeline: edit.clips, at: time)
        }
        let reference = min(plan.cardRect.width, plan.cardRect.height)
        let fontSize = max(reference * 0.032 * edit.captionScale, 11)
        let karaoke = edit.highlightsSpokenWord
        let margin = max(min(plan.cardRect.width, plan.cardRect.height) * 0.05, 8)
        guard let image = CaptionCanvas.image(
            text: cue.text,
            fontSize: fontSize,
            opacity: 0.92,
            activeIndex: karaoke ? cue.activeIndex : nil,
            spokenCount: karaoke ? cue.spokenCount : 0,
            maxWidth: plan.cardRect.width - margin * 2
        ) else {
            return nil
        }
        return (image, overlayFrame(for: image, placing: edit.captionPlacement, marginFraction: 0.05))
    }

    /// Top-left rect of `image` on the recording card, not the padded canvas.
    ///
    /// Captions are chrome on the picture. Placing them in `outputSize` after a Presenter
    /// canvas put them in the margin; `cardRect` is the same slot whether the frame is
    /// full-bleed or sitting on a card.
    private func overlayFrame(
        for image: CGImage,
        placing: OverlayPlacement,
        marginFraction: CGFloat
    ) -> CGRect {
        let card = plan.cardRect
        let reference = min(card.width, card.height)
        return placing.frame(
            for: CGSize(width: image.width, height: image.height),
            in: card,
            margin: max(reference * marginFraction, 8)
        )
    }
}
