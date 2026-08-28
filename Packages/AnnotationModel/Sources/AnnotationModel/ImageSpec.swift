import CoreGraphics
import Foundation

/// A second capture placed on the canvas (docs/03 §3 P2 "image insert", docs/06 M24).
///
/// The pixels travel inside the document rather than as a file reference, for the same
/// reason the subject-lift mask does: a `.kadr` project has to reopen on another machine,
/// and a composition that silently loses one of its images because a staging file was
/// swept away is worse than a larger file.
public struct ImageSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    /// The inserted image, as PNG.
    public var pngData: Data
    /// Where it sits on the canvas, in base-image points.
    public var rect: CGRect
    /// The size it was inserted at, so a size control has something to be relative to.
    /// Without it, repeated slider edits would compound and the image could never be put
    /// back to 100%.
    public var naturalSize: CGSize
    public var opacity: Double
    public var cornerRadius: CGFloat
    /// Drawn behind a drop shadow, which is what makes a stacked composition read as
    /// stacked rather than as one flat picture.
    public var hasShadow: Bool

    public init(
        id: AnnotationID = AnnotationID(),
        pngData: Data,
        rect: CGRect,
        naturalSize: CGSize? = nil,
        opacity: Double = 1,
        cornerRadius: CGFloat = 0,
        hasShadow: Bool = true
    ) {
        self.id = id
        self.pngData = pngData
        self.rect = rect
        self.naturalSize = naturalSize ?? rect.standardized.size
        self.opacity = min(max(opacity, 0), 1)
        self.cornerRadius = max(0, cornerRadius)
        self.hasShadow = hasShadow
    }

    /// The rect an inserted image should land in.
    ///
    /// Scaled down to fit when it is larger than the canvas — dropping a 5K screenshot
    /// onto a 5K screenshot and having it land entirely off the edge is a bad first
    /// second — and centred on the drop point, because that is where the user aimed.
    ///
    /// - Parameters:
    ///   - pixelSize: the inserted image's own size, in pixels.
    ///   - scale: the document's pixels per point, so a Retina insert is not double-size.
    ///   - canvas: the area it has to fit inside, in points.
    public static func placement(
        pixelSize: CGSize,
        scale: CGFloat,
        droppedAt point: CGPoint,
        in canvas: CGRect
    ) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return CGRect(origin: point, size: .zero)
        }
        let natural = CGSize(
            width: pixelSize.width / max(1, scale),
            height: pixelSize.height / max(1, scale)
        )
        // Two thirds, not the whole canvas: an insert that exactly covers the capture is
        // indistinguishable from having replaced it.
        let limit = CGSize(width: canvas.width * 2 / 3, height: canvas.height * 2 / 3)
        let factor = min(1, min(limit.width / natural.width, limit.height / natural.height))
        let size = CGSize(width: natural.width * factor, height: natural.height * factor)

        var rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        // Nudged back inside rather than clipped, so the whole image stays reachable.
        rect.origin.x = min(max(rect.origin.x, canvas.minX), max(canvas.minX, canvas.maxX - size.width))
        rect.origin.y = min(max(rect.origin.y, canvas.minY), max(canvas.minY, canvas.maxY - size.height))
        return rect
    }

    /// How large the image is compared with the size it was inserted at.
    public var scaleFactor: CGFloat {
        guard naturalSize.width > 0 else { return 1 }
        return rect.standardized.width / naturalSize.width
    }

    /// Resizes around the centre, keeping the aspect ratio, for the inspector's slider.
    public mutating func scale(to factor: CGFloat) {
        let clamped = min(max(factor, 0.1), 4)
        let size = CGSize(width: naturalSize.width * clamped, height: naturalSize.height * clamped)
        rect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
