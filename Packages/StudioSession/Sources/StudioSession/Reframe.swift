import CoreGraphics
import Foundation

/// The shape the finished video comes out (docs/09 U3.5).
public enum ReframeAspect: String, Sendable, Hashable, Codable, CaseIterable {
    case original
    case sixteenNine
    case nineSixteen
    case square
    case fourFive

    public var title: String {
        switch self {
        case .original: "Original"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        case .square: "1:1"
        case .fourFive: "4:5"
        }
    }

    /// Width over height, or nil to keep the recording's own.
    public var ratio: Double? {
        switch self {
        case .original: nil
        case .sixteenNine: 16.0 / 9
        case .nineSixteen: 9.0 / 16
        case .square: 1
        case .fourFive: 4.0 / 5
        }
    }
}

/// How a recording is fitted into a new shape (docs/09 U3.5).
public enum ReframeFill: String, Sendable, Hashable, Codable, CaseIterable {
    /// Crop to fill the frame. Nothing is letterboxed, and the edges are lost.
    case fill
    /// Fit the whole recording in, with bars where it does not reach.
    case fit

    public var title: String {
        switch self {
        case .fill: "Fill the frame"
        case .fit: "Show everything"
        }
    }
}

/// Turning a landscape recording into a portrait one, and the rest (docs/09 U3.5).
///
/// The interesting problem is not the crop — it is what happens to the camera. A 16:9
/// recording reframed to 9:16 loses two thirds of its width, and a zoom anchored to
/// something in the lost part now points at nothing. Re-planning the camera is what makes
/// reframing a feature rather than a way to ruin an edit.
public struct Reframe: Sendable, Hashable, Codable {
    public var aspect: ReframeAspect
    public var fill: ReframeFill
    /// Where the crop sits when the recording is wider than the frame, 0…1.
    ///
    /// Half by default, and adjustable, because the interesting part of a screen recording
    /// is rarely dead centre — a sidebar-heavy app puts it well left.
    public var horizontalBias: Double
    public var verticalBias: Double

    public init(
        aspect: ReframeAspect = .original,
        fill: ReframeFill = .fill,
        horizontalBias: Double = 0.5,
        verticalBias: Double = 0.5
    ) {
        self.aspect = aspect
        self.fill = fill
        self.horizontalBias = min(max(horizontalBias, 0), 1)
        self.verticalBias = min(max(verticalBias, 0), 1)
    }

    public static let original = Reframe()

    /// The output's pixel size for a recording of `size`.
    ///
    /// Never larger than the source in either dimension: upscaling a screen recording to
    /// fill a taller frame produces a soft picture, and a soft picture of a screen is
    /// immediately obvious in a way a soft photograph is not.
    public func outputSize(for size: CGSize) -> CGSize {
        guard let ratio = aspect.ratio, size.width > 0, size.height > 0 else { return size }
        let current = size.width / size.height
        if abs(current - ratio) < 0.0001 {
            return size
        }
        return current > ratio
            ? CGSize(width: size.height * ratio, height: size.height)
            : CGSize(width: size.width, height: size.width / ratio)
    }

    /// The part of the recording that ends up on screen.
    ///
    /// For `.fill` this is a crop; for `.fit` it is the whole recording, and the bars are
    /// the renderer's business rather than the geometry's.
    public func sourceRect(for size: CGSize) -> CGRect {
        guard fill == .fill else { return CGRect(origin: .zero, size: size) }
        let output = outputSize(for: size)
        guard output != size else { return CGRect(origin: .zero, size: size) }

        let scale = min(size.width / output.width, size.height / output.height)
        let cropped = CGSize(width: output.width * scale, height: output.height * scale)
        return CGRect(
            x: (size.width - cropped.width) * horizontalBias,
            y: (size.height - cropped.height) * verticalBias,
            width: cropped.width,
            height: cropped.height
        )
    }

    /// Whether this reframe changes anything.
    public var isIdentity: Bool {
        aspect == .original
    }

    // MARK: - Re-planning the camera

    /// The cues, adjusted for the new shape.
    ///
    /// Two corrections, and both are needed:
    ///
    /// * An anchor outside the crop is pulled to the nearest point inside it. Leaving it
    ///   would zoom to somewhere off screen, which shows the viewer a corner of the frame
    ///   and nothing else.
    /// * Magnification is reduced by however much the reframe already zoomed in. A 16:9
    ///   recording cropped to 9:16 is *already* about three times closer; applying the
    ///   original 2× on top of that shows four pixels.
    public func replanning(_ cues: [ZoomCue], in size: CGSize) -> [ZoomCue] {
        guard !isIdentity, fill == .fill else { return cues }
        let crop = sourceRect(for: size)
        guard crop.width > 0, crop.height > 0 else { return cues }

        // How much closer the crop already is than the whole frame.
        let inherentZoom = size.width / crop.width

        return cues.map { cue in
            var replanned = cue
            let anchor = cue.anchor.point(in: size)
            let pulled = CGPoint(
                x: min(max(anchor.x, crop.minX), crop.maxX),
                y: min(max(anchor.y, crop.minY), crop.maxY)
            )
            replanned.anchor = .fixed(pulled)
            // Never below 1: a cue that would zoom *out* is a cue that does nothing.
            replanned.magnification = max(cue.magnification / inherentZoom, 1)
            return replanned
        }
    }

    private enum CodingKeys: String, CodingKey {
        case aspect, fill, horizontalBias, verticalBias
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            aspect: container.decodeIfPresent(ReframeAspect.self, forKey: .aspect) ?? .original,
            fill: container.decodeIfPresent(ReframeFill.self, forKey: .fill) ?? .fill,
            horizontalBias: container.decodeIfPresent(Double.self, forKey: .horizontalBias) ?? 0.5,
            verticalBias: container.decodeIfPresent(Double.self, forKey: .verticalBias) ?? 0.5
        )
    }
}
