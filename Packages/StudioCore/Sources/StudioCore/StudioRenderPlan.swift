import CoreGraphics
import Foundation

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
    /// The camera's position for every instant, over `crop.size`.
    public let viewports: ViewportTimeline
    /// The edited length, which is what the timeline and the cursor are indexed by.
    public let duration: TimeInterval

    /// - Parameters:
    ///   - edit: the edit being rendered.
    ///   - sourceSize: the recording's pixel size.
    ///   - spring: shared with the cursor reconstruction so the camera and the pointer
    ///     settle together rather than one chasing the other.
    public init(edit: StudioEdit, sourceSize: CGSize, spring: MotionSpring = MotionSpring()) {
        self.sourceSize = sourceSize
        let crop = edit.reframe.sourceRect(for: sourceSize)
        self.crop = crop
        outputSize = Self.evenSize(edit.reframe.outputSize(for: sourceSize))
        duration = edit.duration

        // Cues are replanned for the crop and *then* moved into its coordinates. Both
        // steps are needed and neither implies the other: replanning pulls an anchor
        // inside the crop and takes the crop's own zoom back out of the magnification,
        // and the translation is what makes the anchor mean the same point once the
        // timeline is built over the crop rather than the whole frame.
        let replanned = edit.reframe
            .replanning(edit.renderableZooms(in: sourceSize), in: sourceSize)
            .map { $0.translated(by: CGPoint(x: -crop.minX, y: -crop.minY), in: sourceSize) }

        viewports = ViewportTimeline(
            cues: replanned,
            size: crop.size,
            duration: edit.duration,
            spring: spring
        )
    }

    // MARK: - Where a frame comes from

    /// The rect of the source frame that fills the output at `time`, in source pixels.
    public func sourceRect(at time: TimeInterval) -> CGRect {
        let local = viewports.sourceRect(at: time)
        return local.offsetBy(dx: crop.minX, dy: crop.minY)
    }

    /// How much the source is being magnified onto the output at `time`.
    ///
    /// Not the cue's magnification: that is relative to the crop, and the crop is itself
    /// scaled to the output. Overlays drawn at cue magnification would be the wrong size
    /// on every reframe that is not Original.
    public func scale(at time: TimeInterval) -> CGFloat {
        let rect = sourceRect(at: time)
        guard rect.width > 0 else { return 1 }
        return outputSize.width / rect.width
    }

    /// Maps a point in the recording's pixels — top-left origin, as the telemetry records
    /// them — onto the output frame, also top-left.
    ///
    /// Returns a point whether or not it lands inside the frame. A cursor just off the edge
    /// still has to be drawn, because half of it is visible; clipping is the renderer's job
    /// and it does it with pixels rather than by dropping the draw.
    public func outputPoint(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        let rect = sourceRect(at: time)
        guard rect.width > 0, rect.height > 0 else { return point }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width * outputSize.width,
            y: (point.y - rect.minY) / rect.height * outputSize.height
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
}

extension ZoomCue {
    /// The same cue with its anchor moved into another coordinate system.
    ///
    /// A cluster or centre anchor is resolved to a point first: both are defined relative
    /// to a frame size, and after a crop that size is no longer the one they were written
    /// against.
    func translated(by offset: CGPoint, in size: CGSize) -> ZoomCue {
        var moved = self
        let point = anchor.point(in: size)
        moved.anchor = .fixed(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
        return moved
    }
}
