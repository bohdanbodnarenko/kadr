import AnnotationModel
import CoreGraphics
import Foundation

/// The export path, at the density the editor is actually showing (docs/10 R1.5).
///
/// The canvas renders the camera and the progressive blur through the exporter, because a
/// preview that disagrees with the file is worse than a slow one. But at Fit on a 5K capture
/// the window shows perhaps a third of the pixels, and rendering the other two thirds only
/// to have Core Animation throw them away is the stall.
public extension AnnotationExportRenderer {
    /// The pixels-per-point worth rendering a preview at: the density the canvas is being
    /// seen at, never more than the capture has.
    ///
    /// - Parameters:
    ///   - imageScale: the capture's own pixels per point.
    ///   - magnification: the canvas zoom.
    ///   - backingScale: the display's pixels per point.
    static func previewPixelScale(imageScale: CGFloat, magnification: CGFloat, backingScale: CGFloat) -> CGFloat {
        let full = max(imageScale, 0.01)
        let seen = max(magnification, 0.01) * max(backingScale, 1)
        // `min(1, seen / full)` of the capture's own density, i.e. `min(full, seen)`.
        return full * min(1, seen / full)
    }

    /// Renders the whole canvas, un-oriented, at `pixelScale` pixels per point.
    ///
    /// Everything in a document is in points, so a lower density is the same picture with
    /// fewer pixels — except redaction strengths, which are in capture pixels and are
    /// scaled down with the image so a blur looks as strong as it will in the file. A
    /// measurement still reads out in the capture's own pixels.
    func renderPreview(
        baseImage: CGImage,
        document: AnnotationDocument,
        pixelScale: CGFloat,
        randomSeed: UInt64
    ) throws -> CGImage {
        let full = document.baseImage.scale
        let ratio = pixelScale / max(full, 0.01)
        guard ratio < 0.95,
              let reduced = Self.resampled(baseImage, by: ratio)
        else {
            return try render(
                baseImage: baseImage,
                document: document,
                randomSeed: randomSeed,
                applyOrientation: false
            )
        }
        // The density the reduced pixels actually have, after rounding to whole pixels.
        let actual = CGFloat(reduced.width) / CGFloat(max(baseImage.width, 1))
        var preview = document.atPixelScale(full * actual)
        if preview.commands.contains(where: { $0.redaction != nil }) {
            preview.perform { commands in
                for index in commands.indices {
                    guard case var .redaction(spec) = commands[index] else { continue }
                    spec.style = Self.scaled(spec.style, by: actual)
                    commands[index] = .redaction(spec)
                }
            }
        }
        return try render(
            baseImage: reduced,
            document: preview,
            options: RenderOptions(randomSeed: randomSeed, applyOrientation: false, labelScale: full)
        )
    }

    /// A redaction's strength at a lower pixel density.
    static func scaled(_ style: RedactionStyle, by ratio: CGFloat) -> RedactionStyle {
        switch style {
        case let .blur(radius): .blur(radius: max(radius * ratio, 0.5))
        case let .pixelate(cellSize): .pixelate(cellSize: max(cellSize * ratio, 2))
        case .erase: .erase
        }
    }

    /// `image` at `ratio` of its size, never smaller than one pixel a side.
    ///
    /// Not `downscaled(_:by:)`: that one is for exports and clamps at a quarter, where a
    /// preview of a 5K capture at Fit wants far less.
    static func resampled(_ image: CGImage, by ratio: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard width < image.width || height < image.height,
              let context = makeContext(width: width, height: height, matching: image)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
