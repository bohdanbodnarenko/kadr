import AnnotationModel
import CoreGraphics
import CoreImage
import Foundation

/// A whole-capture rendering of one redaction style, shown while a box is being dragged.
///
/// The exact preview is a crop of the box, redacted on its own — and a moving box is a new
/// crop on every mouse-move, which no cache can hit. Rendering the effect over the whole
/// capture once, and showing the part under the box, makes the drag free: the pixels are
/// already there, and moving the box only moves which part is shown (docs/10 R1).
///
/// It is an approximation. A blur here samples past the box's edge and a mosaic's grid is
/// anchored to the capture rather than to the box; both are invisible at drag speed, and the
/// exact render replaces this the moment the pointer lets go.
public struct RedactionGestureImage: Sendable {
    /// The effect over the whole capture, at reduced density.
    public let image: CGImage
    /// Base-image pixels per pixel of `image`.
    public let factor: CGFloat

    /// The part of `image` covering a box in base-image pixels, and where that part sits
    /// in the same base-image pixel space.
    ///
    /// Snapped outward to whole stand-in pixels, so a mosaic's cells land on the capture's
    /// grid at their true size rather than being stretched to fit the box. The caller
    /// clips to the box.
    public func region(covering box: CGRect) -> (image: CGImage, pixelRect: CGRect)? {
        guard factor > 0, !box.isNull, box.width > 0, box.height > 0 else { return nil }
        let cells = Self.enclosingCells(of: box, factor: factor)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !cells.isNull, cells.width >= 1, cells.height >= 1,
              let cropped = image.cropping(to: cells)
        else { return nil }
        let pixelRect = CGRect(
            x: cells.minX * factor,
            y: cells.minY * factor,
            width: cells.width * factor,
            height: cells.height * factor
        )
        return (cropped, pixelRect)
    }

    /// The stand-in pixels, whole ones, that cover `box`.
    static func enclosingCells(of box: CGRect, factor: CGFloat) -> CGRect {
        let minX = (box.minX / factor).rounded(.down)
        let minY = (box.minY / factor).rounded(.down)
        let maxX = (box.maxX / factor).rounded(.up)
        let maxY = (box.maxY / factor).rounded(.up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public extension RedactionRasterizer {
    /// The longest edge a blur stand-in is rendered at. A blur has no detail to lose, and a
    /// 5K capture blurred at full size is a CoreImage pass the drag cannot afford twice.
    static let gestureBlurLongestEdge: CGFloat = 2048

    /// Renders `style` over the whole of `image`, for dragging. `nil` for erase, whose exact
    /// preview is already cheap, and for an image that cannot be rendered.
    func gestureImage(for style: RedactionStyle, from image: CGImage) -> RedactionGestureImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        switch style {
        case let .blur(radius):
            return gestureBlur(image, sigma: max(radius, 1))
        case let .pixelate(cellSize):
            return gestureMosaic(image, cell: Self.cellPixels(cellSize))
        case .erase:
            return nil
        }
    }

    /// How many base-image pixels one blur stand-in pixel covers.
    static func gestureBlurFactor(width: Int, height: Int) -> CGFloat {
        let longest = CGFloat(max(width, height))
        return max(1, longest / gestureBlurLongestEdge)
    }

    private func gestureBlur(_ image: CGImage, sigma: CGFloat) -> RedactionGestureImage? {
        let factor = Self.gestureBlurFactor(width: image.width, height: image.height)
        var input = CIImage(cgImage: image)
        if factor > 1 {
            input = input.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 1 / factor,
                kCIInputAspectRatioKey: 1
            ])
        }
        let extent = input.extent.integral
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma / factor])
            .cropped(to: extent)
        guard let rendered = KadrRenderContext.shared.createCGImage(blurred, from: extent) else {
            return nil
        }
        return RedactionGestureImage(image: rendered, factor: factor)
    }

    /// One stand-in pixel per mosaic cell: the capture shrunk by the cell size, so each
    /// pixel is its cell's average. Shown with nearest-neighbour magnification it *is* an
    /// averaged mosaic, at a sliver of the memory of a full-size one — a 5K capture is
    /// 59 MB at full size and well under 1 MB at a 10-pixel cell.
    private func gestureMosaic(_ image: CGImage, cell: Int) -> RedactionGestureImage? {
        let factor = CGFloat(cell)
        let width = Int((CGFloat(image.width) / factor).rounded(.up))
        let height = Int((CGFloat(image.height) / factor).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: Self.workingSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        // Exactly `cell` capture pixels per stand-in pixel, anchored at the top: CoreGraphics
        // draws from the bottom, so a partial last row would otherwise shift every cell.
        let drawnWidth = CGFloat(image.width) / factor
        let drawnHeight = CGFloat(image.height) / factor
        context.draw(
            image,
            in: CGRect(x: 0, y: CGFloat(height) - drawnHeight, width: drawnWidth, height: drawnHeight)
        )
        guard let rendered = context.makeImage() else { return nil }
        return RedactionGestureImage(image: rendered, factor: factor)
    }
}
