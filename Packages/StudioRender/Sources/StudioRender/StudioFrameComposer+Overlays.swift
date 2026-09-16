import CoreGraphics
import CoreImage
import Foundation
import os
import Shared
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
    /// Not cached, unlike the captions: its progress changes every frame and so does its
    /// scale while the camera moves, so a cache would be all misses — and the plate is a
    /// few hundred pixels square, which costs little to fill.
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
        // Quantised, so the fade-out is a few dozen distinct pictures the cache can hold
        // rather than a fresh one every frame. A sixty-fourth of full opacity is a step of
        // under half a grey level on the pill and is not something an eye can find.
        let opacity = OverlayImageCache.quantised(
            ClickRippleMetrics.captionOpacity(elapsed: time - last.time)
        )
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
        guard let image = overlayCache.caption(CaptionKey(
            text: text,
            fontSize: fontSize,
            opacity: opacity,
            appearance: edit.keystrokeAppearance
        )) else {
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
        guard let image = overlayCache.caption(CaptionKey(
            text: cue.text,
            fontSize: fontSize,
            opacity: 0.92,
            activeIndex: karaoke ? cue.activeIndex : nil,
            spokenCount: karaoke ? cue.spokenCount : 0,
            maxWidth: plan.cardRect.width - margin * 2
        )) else {
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

// MARK: - Caching the rasterised captions

/// Everything that decides what a caption pill looks like.
///
/// The full argument list of `CaptionCanvas.image`, so two keys that compare equal are
/// guaranteed to draw the same picture — which is what makes it safe for the cache to hand
/// one back in place of the other.
struct CaptionKey: Hashable, Sendable {
    var text: String
    var fontSize: CGFloat
    var opacity: Double
    var appearance: OverlayChromeAppearance = .dark
    var activeIndex: Int?
    var spokenCount: Int = 0
    var maxWidth: CGFloat?

    /// Draws the caption this key describes, uncached.
    func draw() -> CGImage? {
        CaptionCanvas.image(
            text: text,
            fontSize: fontSize,
            opacity: opacity,
            appearance: appearance,
            activeIndex: activeIndex,
            spokenCount: spokenCount,
            maxWidth: maxWidth
        )
    }
}

/// Recently drawn captions (docs/09 U3.2).
///
/// A keystroke caption holds for most of a second and a speech cue for several, and the
/// text in either changes a few times a second at most — yet CoreText laid it out and
/// CoreGraphics filled it on every frame. Most frames now find the picture here.
///
/// A class behind a lock because the composer is a `Sendable` value that an
/// `AVVideoCompositing` implementation calls from several threads at once; copies of a
/// composer share one cache, which is harmless because the key is the whole input.
///
/// Most-recent-first, bounded twice. By count, sized so a whole fade fits: a keystroke
/// caption fades through about thirty quantised steps, and the same chord pressed again
/// fades through the same thirty pictures — so with room for them, every repeat of "⌘S"
/// is free. By bytes, because a wrapped speech caption on a 4K card is a megabyte or more
/// and a count alone would let a few dozen of them sit in memory.
///
/// Drawing happens outside the lock. Two threads that miss on the same key both draw it —
/// wasted work, but the same picture — rather than one waiting on the other's CoreText.
final class OverlayImageCache: Sendable {
    static let capacity = 64
    static let byteLimit = 24 * 1024 * 1024
    /// Opacity steps per unit, for `quantised(_:)`.
    static let opacitySteps: Double = 64

    private struct Entry: Sendable {
        let key: CaptionKey
        let image: CGImage?

        var bytes: Int {
            image.map { $0.bytesPerRow * $0.height } ?? 0
        }
    }

    private struct State: Sendable {
        var entries: [Entry] = []
        var bytes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `opacity` rounded to the nearest sixty-fourth, and clamped to 0…1.
    static func quantised(_ opacity: Double) -> Double {
        (min(max(opacity, 0), 1) * opacitySteps).rounded() / opacitySteps
    }

    /// The caption for `key`, drawn now or remembered from a recent frame.
    func caption(_ key: CaptionKey) -> CGImage? {
        let hit = state.withLock { state -> Entry? in
            guard let index = state.entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = state.entries.remove(at: index)
            state.entries.insert(entry, at: 0)
            return entry
        }
        if let hit {
            return hit.image
        }
        let entry = Entry(key: key, image: key.draw())
        state.withLock { state in
            guard !state.entries.contains(where: { $0.key == key }) else { return }
            state.entries.insert(entry, at: 0)
            state.bytes += entry.bytes
            // The newest entry always stays, however large: it is the one on screen.
            while state.entries.count > 1,
                  state.entries.count > Self.capacity || state.bytes > Self.byteLimit {
                state.bytes -= state.entries.removeLast().bytes
            }
        }
        return entry.image
    }

    /// How many captions are remembered, and their size. For tests.
    var usage: (count: Int, bytes: Int) {
        state.withLock { ($0.entries.count, $0.bytes) }
    }
}
