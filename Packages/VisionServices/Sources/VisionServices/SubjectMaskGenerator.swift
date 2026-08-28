import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Shared
import UniformTypeIdentifiers
import Vision

/// Separates the subject of a capture from its background (docs/04 §6, docs/06 M23).
///
/// `VNGenerateForegroundInstanceMaskRequest` is the same segmentation macOS uses for
/// "lift subject from background" in Preview and Quick Look, which matters for a reason
/// beyond convenience: a user who has seen the OS do it on this exact screenshot expects
/// the same cut-out, and anything else reads as a worse implementation.
///
/// Lives in VisionServices, so only the helper process ever loads the model
/// (docs/04 §1, §7 rule 4).
public struct SubjectMaskGenerator: Sendable {
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    public init() {}

    /// What the segmentation found.
    public struct Result: Sendable {
        /// A grayscale mask at the source image's pixel size: white is subject.
        public var mask: CGImage
        public var subjectCount: Int
    }

    /// Segments `image`, or returns nil when there is no subject in it.
    ///
    /// No subject is a normal answer: a screenshot of a spreadsheet has none, and the
    /// editor should say so plainly rather than report a failure.
    public func mask(of image: CGImage) throws -> Result? {
        let state = signposter.beginInterval("subjectMask")
        defer { signposter.endInterval("subjectMask", state) }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            logger.info("No subject found in the capture")
            return nil
        }

        // Every instance at once: "remove the background" means keeping everything that
        // is not background, not picking one of several people out of a group photo.
        let buffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        guard let mask = Self.grayscaleImage(from: buffer, size: CGSize(width: image.width, height: image.height))
        else {
            throw VisionServiceError.maskFailed
        }
        return Result(mask: mask, subjectCount: observation.allInstances.count)
    }

    /// Segments the image at `source` and writes the mask as a PNG.
    @discardableResult
    public func writeMask(of source: URL, to destination: URL) throws -> SubjectMaskResponse {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw VisionServiceError.couldNotDecodeImage
        }

        guard let result = try mask(of: image) else {
            return SubjectMaskResponse(maskPath: nil, subjectCount: 0)
        }
        try Self.writePNG(result.mask, to: destination)
        return SubjectMaskResponse(maskPath: destination.path, subjectCount: result.subjectCount)
    }

    /// Vision hands back a one-component float buffer; ImageIO wants a `CGImage`.
    private static func grayscaleImage(from buffer: CVPixelBuffer, size: CGSize) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        // The scaled mask should already match, but a rounding difference here would
        // misalign the cut-out by a pixel along one edge, which is very visible.
        let scale = CGAffineTransform(
            scaleX: size.width / max(1, ciImage.extent.width),
            y: size.height / max(1, ciImage.extent.height)
        )
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(
            ciImage.transformed(by: scale),
            from: CGRect(origin: .zero, size: size),
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw VisionServiceError.maskFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VisionServiceError.maskFailed
        }
    }
}
