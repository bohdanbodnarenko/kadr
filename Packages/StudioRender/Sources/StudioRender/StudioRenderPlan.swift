import CoreGraphics
import Foundation
import StudioSession

/// Everything a frame needs to know about where things go, worked out once (docs/09 U3.3).
///
/// The preview and the export both build one of these from the same edit and then agree by
/// construction. That is the whole point: a preview that resolves the crop, the cues or the
/// output size its own way is a preview that lies, and the lie only shows up after a
/// five-minute render.
///
/// Pure geometry — no CoreImage, no AVFoundation, no pixels. Which means the part of the
/// renderer most likely to be wrong is the part that can be tested with a table.
public struct StudioRenderPlan: Sendable {
    /// The recording's own pixel size.
    public let sourceSize: CGSize
    /// The part of the recording that survives the reframe, in source pixels.
    public let crop: CGRect
    /// The exported frame's pixel size.
    public let outputSize: CGSize
    /// Where the recording card sits inside `outputSize`, top-left origin.
    public let cardRect: CGRect
    /// Rounded-rect radius of the card, in output pixels.
    public let cardCornerRadius: CGFloat
    /// The camera's position for every instant, over `crop.size`.
    public let viewports: ViewportTimeline
    /// The edited length, which is what the timeline and the cursor are indexed by.
    public let duration: TimeInterval
    /// Whether the output frame is filled or fitted (docs/09 U3.5).
    ///
    /// Kept because it decides which way the last fraction of a pixel goes, and the two
    /// answers are visibly different: `.fill` promises no bars, so it covers the frame and
    /// lets the overflow be cropped; `.fit` promises nothing is lost, so it fits inside and
    /// accepts bars. Rounding the output to even pixels leaves a pixel or two of slack even
    /// when the shapes match, and fitting `.fill` put a thin black line along the top and
    /// bottom of an export that had asked for none.
    public let fill: ReframeFill

    /// - Parameters:
    ///   - edit: the edit being rendered.
    ///   - sourceSize: the recording's pixel size.
    ///   - spring: the camera's easing. Defaults to the edit's zoom style, which is
    ///     independent of how the pointer is smoothed (CleanShot §14.3).
    ///   - pointer: edited-time pointer samples, in source pixels. Used only by cues
    ///     whose anchor follows the pointer.
    public init(
        edit: StudioEdit,
        sourceSize: CGSize,
        spring: MotionSpring? = nil,
        maxLongestEdge: Int? = nil,
        pointer: [PointerSample] = []
    ) {
        self.sourceSize = sourceSize
        let crop = edit.sourceRect(for: sourceSize)
        self.crop = crop
        let contentSize = Self.evenSize(edit.outputSize(for: sourceSize))
        let laid = edit.canvas.layout(cardSize: contentSize)
        let canvas = Self.scaled(Self.evenSize(laid.canvasSize), maxLongestEdge: maxLongestEdge)
        let scaleX = canvas.width / max(laid.canvasSize.width, 1)
        let scaleY = canvas.height / max(laid.canvasSize.height, 1)
        outputSize = canvas
        cardRect = CGRect(
            x: laid.cardRect.minX * scaleX,
            y: laid.cardRect.minY * scaleY,
            width: laid.cardRect.width * scaleX,
            height: laid.cardRect.height * scaleY
        )
        cardCornerRadius = laid.cornerRadius * min(scaleX, scaleY)
        duration = edit.duration
        fill = edit.reframe.fill

        // Cues are replanned for the crop and *then* moved into its coordinates. Both
        // steps are needed and neither implies the other: replanning pulls an anchor
        // inside the crop and takes the crop's own zoom back out of the magnification,
        // and the translation is what makes the anchor mean the same point once the
        // timeline is built over the crop rather than the whole frame.
        let replanned = edit.renderableZooms(in: sourceSize)
            .map { $0.translated(by: CGPoint(x: -crop.minX, y: -crop.minY), in: sourceSize) }
        let localPointer = pointer.map { sample in
            PointerSample(
                time: sample.time,
                position: CGPoint(
                    x: sample.position.x - crop.minX,
                    y: sample.position.y - crop.minY
                ),
                cursorIndex: sample.cursorIndex
            )
        }

        viewports = ViewportTimeline(
            cues: replanned,
            size: crop.size,
            duration: edit.duration,
            spring: spring ?? MotionSpring(edit.zoomStyle),
            pointer: localPointer
        )
    }

    // MARK: - Where a frame comes from

    /// The rect of the source frame that fills the output at `time`, in source pixels.
    public func sourceRect(at time: TimeInterval) -> CGRect {
        let local = viewports.sourceRect(at: time)
        return local.offsetBy(dx: crop.minX, dy: crop.minY)
    }

    /// How the visible part of the recording sits inside the output frame at `time`.
    ///
    /// One answer to three questions that have to agree — how the frame itself is scaled,
    /// how big an overlay is, and where a recorded point lands. They were answered
    /// separately, each by `outputSize.width / rect.width`, and "Show everything" is the
    /// case where that is wrong: `.fit` hands back the *whole* recording and leaves the
    /// letterboxing to the renderer, which had no letterbox logic at all. Scaling by width
    /// alone put a 1920×1080 recording flush against the bottom of a 9:16 frame under a
    /// 739-pixel black bar — and in the other direction it scaled past the frame and
    /// cropped, which is the one thing "Show everything" promises not to do.
    ///
    /// Fitting by the tighter axis and centring is all it takes; `.fill` and Original hand
    /// back a rect that already matches the output's shape, so for them both axes give the
    /// same scale and the offset is zero. Only `.fit` moves.
    public struct Presentation: Sendable, Hashable {
        /// Output pixels per source pixel — the same in both axes, so nothing is stretched.
        public let scale: CGFloat
        /// Where the scaled content's top-left corner sits in the output frame.
        public let origin: CGPoint

        public init(scale: CGFloat, origin: CGPoint) {
            self.scale = scale
            self.origin = origin
        }
    }

    public func presentation(at time: TimeInterval) -> Presentation {
        presentation(for: sourceRect(at: time))
    }

    /// The same, for a rect the caller has already looked up.
    ///
    /// Worth the second entry point: `sourceRect(at:)` walks the integrated viewport table,
    /// and asking for the rect and then asking for the presentation *of that time* walks it
    /// twice. Doing that in `sample`, `scale(at:)` and `outputPoint` tripled the per-frame
    /// lookups and the flat-cost budget in `TimeSortedLookupTests` caught it immediately,
    /// which is the entire reason that test is a gate rather than a comment.
    public func presentation(for rect: CGRect) -> Presentation {
        let card = cardRect
        guard card.width > 0, card.height > 0, rect.width > 0, rect.height > 0 else {
            return Presentation(scale: 1, origin: card.origin)
        }
        let scale = switch fill {
        case .fit: min(card.width / rect.width, card.height / rect.height)
        // Covers rather than fits, so the card is full and the surplus is cropped by the
        // composer's card clip — which is what "Fill the frame" says on the control.
        case .fill: max(card.width / rect.width, card.height / rect.height)
        }
        return Presentation(
            scale: scale,
            origin: CGPoint(
                x: card.minX + (card.width - rect.width * scale) / 2,
                y: card.minY + (card.height - rect.height * scale) / 2
            )
        )
    }

    /// How much the source is being magnified onto the output at `time`.
    ///
    /// Not the cue's magnification: that is relative to the crop, and the crop is itself
    /// scaled to the output. Overlays drawn at cue magnification would be the wrong size
    /// on every reframe that is not Original.
    public func scale(at time: TimeInterval) -> CGFloat {
        presentation(at: time).scale
    }

    /// Maps a point in the recording's pixels — top-left origin, as the telemetry records
    /// them — onto the output frame, also top-left.
    ///
    /// Returns a point whether or not it lands inside the frame. A cursor just off the edge
    /// still has to be drawn, because half of it is visible; clipping is the renderer's job
    /// and it does it with pixels rather than by dropping the draw.
    public func outputPoint(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        outputPoint(point, in: sourceRect(at: time))
    }

    /// The same, for a rect the caller already has.
    ///
    /// Through the same presentation the frame itself goes through. Mapping each axis onto
    /// the full output independently would stretch a letterboxed `.fit` frame and put the
    /// cursor somewhere the picture underneath it is not.
    public func outputPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return point }
        let presentation = presentation(for: rect)
        return CGPoint(
            x: presentation.origin.x + (point.x - rect.minX) * presentation.scale,
            y: presentation.origin.y + (point.y - rect.minY) * presentation.scale
        )
    }

    /// Whether the camera is moving at `time`, and so whether the frame wants motion blur.
    public func isMoving(at time: TimeInterval) -> Bool {
        viewports.isMoving(at: time)
    }

    // MARK: - Sizes

    /// Rounds a size to even pixels.
    ///
    /// Not fussiness: H.264 and HEVC encode in macroblocks, and an odd dimension is either
    /// rejected outright or silently padded with a green column that survives into the
    /// file. Rounding down rather than up keeps the frame inside the source.
    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(2, (size.width / 2).rounded(.down) * 2),
            height: max(2, (size.height / 2).rounded(.down) * 2)
        )
    }

    /// Shrinks a frame so its longest edge is at most `maxLongestEdge`, keeping aspect.
    ///
    /// 1080p means 1920 on the long side, not 1080: a 1920×1080 recording that "exported at
    /// 1080p" by capping at 1080 would become 1080×608, which is not Full HD. Unchanged
    /// when the frame already fits, so Original is a no-op.
    static func scaled(_ size: CGSize, maxLongestEdge: Int?) -> CGSize {
        guard let maxLongestEdge, maxLongestEdge > 0 else { return size }
        let longest = max(size.width, size.height)
        guard longest > CGFloat(maxLongestEdge) else { return size }
        let scale = CGFloat(maxLongestEdge) / longest
        return evenSize(CGSize(width: size.width * scale, height: size.height * scale))
    }
}

extension ZoomCue {
    /// The same cue with its anchor moved into another coordinate system.
    ///
    /// A cluster or centre anchor is resolved to a point first: both are defined relative
    /// to a frame size, and after a crop that size is no longer the one they were written
    /// against.
    func translated(by offset: CGPoint, in size: CGSize) -> ZoomCue {
        var moved = self
        if anchor.followsPointer {
            return moved
        }
        let point = anchor.point(in: size)
        moved.anchor = .fixed(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
        return moved
    }
}
