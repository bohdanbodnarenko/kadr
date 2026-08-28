import AnnotationModel
import CoreGraphics
import CoreImage
import Foundation
import os
import Shared

/// Applies background removal to the base image (docs/03 §3 P3, docs/06 M23).
///
/// Like redaction, this happens to the image *before* anything is drawn on it, because a
/// cut-out that was only an overlay would still carry the background in the exported file
/// — and unlike a blur, the whole point here is that the background is gone.
///
/// The mask travels with the document, so the composite is reproducible from a `.kadr`
/// file alone, with no call back to Vision and no scratch file to lose.
public struct SubjectLiftCompositor: Sendable {
    private let logger = KadrLog.logger(.capture)

    public init() {}

    /// Cuts the subject out of `image`, or returns it untouched when the mask cannot be
    /// read — a failure here should cost the user their background removal, not their
    /// screenshot.
    public func apply(_ spec: SubjectLiftSpec, to image: CGImage) -> CGImage {
        guard let mask = Self.decodeMask(spec.maskPNG) else {
            logger.error("Subject-lift mask could not be decoded; leaving the image alone")
            return image
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let source = CIImage(cgImage: image)
        let extent = source.extent

        // The mask is generated at the capture's pixel size, but a document that was
        // resized — or a mask from a differently scaled copy — must still line up.
        let maskImage = CIImage(cgImage: mask).transformed(by: CGAffineTransform(
            scaleX: extent.width / max(1, CGFloat(mask.width)),
            y: extent.height / max(1, CGFloat(mask.height))
        ))

        let background = switch spec.background {
        case .transparent:
            CIImage.empty()
        case let .color(colour):
            CIImage(color: CIColor(
                red: colour.red,
                green: colour.green,
                blue: colour.blue,
                alpha: colour.alpha
            )).cropped(to: extent)
        }

        let blended = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: maskImage
        ])
        guard let result = context.createCGImage(blended, from: extent) else {
            logger.error("Subject lift could not be composited; leaving the image alone")
            return image
        }
        return result
    }

    private static func decodeMask(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            pngDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
