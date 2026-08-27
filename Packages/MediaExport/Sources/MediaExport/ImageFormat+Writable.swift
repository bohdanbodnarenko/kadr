import ImageIO
import Shared
import UniformTypeIdentifiers

public extension ImageFormat {
    /// Whether ImageIO on this system can *write* the format.
    ///
    /// This is a runtime question, not a compile-time one. macOS reads WebP but has
    /// never shipped a WebP encoder, so `CGImageDestinationCreateWithData` returns nil
    /// for it — the PRD lists WebP as a Phase 1 export format, and that is the platform's
    /// answer. Asking ImageIO rather than hard-coding a list means the day macOS gains
    /// an encoder, Kadr offers it without a code change.
    var isWritable: Bool {
        Self.writableTypeIdentifiers.contains(contentType.identifier)
    }

    /// The formats worth offering in a format picker.
    static var writable: [ImageFormat] {
        allCases.filter(\.isWritable)
    }

    /// Queried once: the answer cannot change while the process runs.
    private static let writableTypeIdentifiers: Set<String> =
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
}
