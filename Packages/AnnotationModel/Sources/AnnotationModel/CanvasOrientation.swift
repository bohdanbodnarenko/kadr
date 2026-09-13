import CoreGraphics
import Foundation

/// A 90°-step orientation of the capture, stored separately from the pixels
/// (docs/03 §3 P2, CleanShot 4.8).
///
/// The base image stays immutable. Rotate and flip are canvas chrome: they change how
/// the capture is shown and exported, and they undo as one history step each.
public struct CanvasOrientation: Codable, Hashable, Sendable {
    /// Clockwise quarter-turns of the original, 0...3.
    public var quarterTurnsCW: Int
    /// Left-right mirror of the original, applied before the quarter-turns.
    public var isFlippedHorizontally: Bool

    public init(quarterTurnsCW: Int = 0, isFlippedHorizontally: Bool = false) {
        self.quarterTurnsCW = ((quarterTurnsCW % 4) + 4) % 4
        self.isFlippedHorizontally = isFlippedHorizontally
    }

    public static let identity = CanvasOrientation()

    public var isIdentity: Bool {
        quarterTurnsCW == 0 && !isFlippedHorizontally
    }

    /// Size after this orientation is applied.
    public func orientedSize(of size: CGSize) -> CGSize {
        quarterTurnsCW % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Rotate the currently displayed image 90° clockwise.
    public func rotatedClockwise() -> CanvasOrientation {
        CanvasOrientation(quarterTurnsCW: quarterTurnsCW + 1, isFlippedHorizontally: isFlippedHorizontally)
    }

    /// Mirror the currently displayed image left-to-right.
    public func flippedHorizontally() -> CanvasOrientation {
        if quarterTurnsCW % 2 == 0 {
            return CanvasOrientation(
                quarterTurnsCW: quarterTurnsCW,
                isFlippedHorizontally: !isFlippedHorizontally
            )
        }
        // A visual horizontal flip of a 90°/270° image is a vertical flip of the original,
        // which is a horizontal flip plus a half turn.
        return CanvasOrientation(
            quarterTurnsCW: quarterTurnsCW + 2,
            isFlippedHorizontally: !isFlippedHorizontally
        )
    }

    /// Mirror the currently displayed image top-to-bottom (CleanShot §8.2).
    ///
    /// Stored as a horizontal flip plus a half turn when the canvas is upright, and as a
    /// horizontal flip alone when it is on its side — the same composition that makes a
    /// visual vertical flip of a rotated image look like a horizontal flip of the original.
    public func flippedVertically() -> CanvasOrientation {
        if quarterTurnsCW % 2 == 0 {
            return CanvasOrientation(
                quarterTurnsCW: quarterTurnsCW + 2,
                isFlippedHorizontally: !isFlippedHorizontally
            )
        }
        return CanvasOrientation(
            quarterTurnsCW: quarterTurnsCW,
            isFlippedHorizontally: !isFlippedHorizontally
        )
    }

    /// Maps a point in unoriented canvas space into the oriented view.
    public func apply(_ point: CGPoint, unoriented size: CGSize) -> CGPoint {
        var point = point
        if isFlippedHorizontally {
            point.x = size.width - point.x
        }
        switch quarterTurnsCW {
        case 1:
            return CGPoint(x: size.height - point.y, y: point.x)
        case 2:
            return CGPoint(x: size.width - point.x, y: size.height - point.y)
        case 3:
            return CGPoint(x: point.y, y: size.width - point.x)
        default:
            return point
        }
    }

    /// Inverse of `apply`: an oriented-view click back into unoriented canvas space.
    public func unapply(_ point: CGPoint, unoriented size: CGSize) -> CGPoint {
        var point = point
        switch quarterTurnsCW {
        case 1:
            point = CGPoint(x: point.y, y: size.height - point.x)
        case 2:
            point = CGPoint(x: size.width - point.x, y: size.height - point.y)
        case 3:
            point = CGPoint(x: size.width - point.y, y: point.x)
        default:
            break
        }
        if isFlippedHorizontally {
            point.x = size.width - point.x
        }
        return point
    }

    /// Layer transform about the unoriented canvas centre, for a flipped NSView.
    public func viewTransform() -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        if isFlippedHorizontally {
            transform = transform.scaledBy(x: -1, y: 1)
        }
        if quarterTurnsCW != 0 {
            transform = transform.rotated(by: -CGFloat(quarterTurnsCW) * .pi / 2)
        }
        return transform
    }

    /// Applies this orientation to a bitmap. Identity returns `image` unchanged.
    public func applying(to image: CGImage) -> CGImage? {
        guard !isIdentity else { return image }
        var current = image
        if isFlippedHorizontally {
            guard let flipped = Self.drawn(
                width: current.width,
                height: current.height,
                from: current,
                body: { context in
                    context.translateBy(x: CGFloat(current.width), y: 0)
                    context.scaleBy(x: -1, y: 1)
                    context.draw(
                        current,
                        in: CGRect(x: 0, y: 0, width: current.width, height: current.height)
                    )
                }
            ) else {
                return nil
            }
            current = flipped
        }
        for _ in 0 ..< quarterTurnsCW {
            guard let rotated = Self.drawn(
                width: current.height,
                height: current.width,
                from: current,
                body: { context in
                    context.translateBy(x: CGFloat(current.height), y: 0)
                    context.rotate(by: .pi / 2)
                    context.draw(
                        current,
                        in: CGRect(x: 0, y: 0, width: current.width, height: current.height)
                    )
                }
            ) else {
                return nil
            }
            current = rotated
        }
        return current
    }

    private static func drawn(
        width: Int,
        height: Int,
        from image: CGImage,
        body: (CGContext) -> Void
    ) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        body(context)
        return context.makeImage()
    }
}
