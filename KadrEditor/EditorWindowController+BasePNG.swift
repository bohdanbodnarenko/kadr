import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The capture as PNG bytes, for autosave and project saves (docs/10 R2.6).
///
/// The base image never changes, so its PNG and that PNG's checksum are worked out once
/// per window. Two things changed about *when*:
///
/// * A capture that is already a PNG is not re-encoded at all — its own bytes, read once at
///   open, are the PNG. Re-encoding a 5K screenshot on the main actor was most of the time
///   it took the editor window to appear.
/// * Anything else (a JPEG, a HEIC dragged in from Finder) is encoded the first time it is
///   needed, on whichever thread needs it — autosave's detached writer, normally.
///
/// Thread-safe: the first caller encodes under the lock and later callers get its result.
final nonisolated class BaseImagePNG: @unchecked Sendable {
    private let image: CGImage
    private let lock = NSLock()
    private var png: Data?
    private var crc: UInt32?

    /// - Parameter png: the capture's PNG bytes when they are already known — a `.kadr`'s
    ///   stored base image, or the capture file itself when it is a PNG.
    init(image: CGImage, png: Data?) {
        self.image = image
        self.png = png
    }

    /// Whether `data`, as read by `source`, is a PNG this can keep as is.
    static func isPNG(_ source: CGImageSource) -> Bool {
        (CGImageSourceGetType(source) as String?) == UTType.png.identifier
    }

    /// The PNG bytes, encoding them on this thread the first time if nobody has yet.
    func data() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try encodedLocked()
    }

    /// A `.kadr` payload for `document`, with the base image's checksum filled in so the
    /// archive writer does not recompute it for every autosave.
    func contents(for document: AnnotationDocument) throws -> KadrDocumentFile.Contents {
        lock.lock()
        defer { lock.unlock() }
        let png = try encodedLocked()
        let checksum = crc ?? KadrDocumentFile.crc32(of: png)
        crc = checksum
        return KadrDocumentFile.Contents(document: document, baseImagePNG: png, baseImageCRC32: checksum)
    }

    private func encodedLocked() throws -> Data {
        if let png {
            return png
        }
        let encoded = try Self.encode(image)
        png = encoded
        return encoded
    }

    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw EncodeError.couldNotEncode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EncodeError.couldNotEncode
        }
        return data as Data
    }

    enum EncodeError: LocalizedError {
        case couldNotEncode

        var errorDescription: String? {
            "Kadr could not encode the capture as PNG."
        }
    }
}
