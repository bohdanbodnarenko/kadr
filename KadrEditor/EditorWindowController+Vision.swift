import Foundation
import ImageIO
import Shared
import UniformTypeIdentifiers

extension EditorWindowController {
    static func decodeImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Recovers the capture's scale from its DPI tag, defaulting to 1 for images that
    /// carry none.
    static func scale(of source: CGImageSource) -> CGFloat {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0
        else { return 1 }
        return max(1, CGFloat((dpi / 72).rounded()))
    }

    func analyzeForRedaction(_ image: CGImage) async throws -> VisionAnalysis {
        try await vision.analyze(
            image,
            options: TextRecognitionOptions(
                detectsCodes: false,
                includeRedactionCandidates: true
            )
        )
    }

    /// Asks the helper to segment the subject and hands back the mask (docs/06 M23).
    ///
    /// The base image is written to a scratch PNG rather than the capture file being
    /// passed straight through: a `.kadr` project's base image lives inside a zip, and a
    /// mask has to match the pixels the document is actually built on.
    func liftSubject() async throws -> Data? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-lift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("base.png")
        try Self.writePNG(baseImage, to: source)

        let response = try await vision.subjectMask(SubjectMaskRequest(
            sourcePath: source.path,
            destinationPath: scratch.appendingPathComponent("mask.png").path
        ))
        // Let go so the helper can start its idle countdown and give the model back
        // (docs/04 §1).
        vision.disconnect()

        guard let maskPath = response.maskPath else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: maskPath))
    }

    static func pngData(of image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OpenError.unreadableImage(URL(fileURLWithPath: "/"))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OpenError.unreadableImage(URL(fileURLWithPath: "/"))
        }
        return data as Data
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OpenError.unreadableImage(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OpenError.unreadableImage(url)
        }
    }
}
