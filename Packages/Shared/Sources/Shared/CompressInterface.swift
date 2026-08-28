import CoreGraphics
import Foundation

/// A capture to re-encode smaller (docs/09 U2.4).
///
/// A path rather than the pixels: the point of doing this in the helper is that the agent
/// never holds a decoded 5K bitmap, and shipping one across XPC to avoid holding it would
/// be self-defeating.
public struct CompressRequest: Codable, Sendable, Hashable {
    public var sourcePath: String
    /// Where to write the result. The caller owns the file; the helper only fills it.
    public var destinationPath: String
    /// The size to aim for, in bytes.
    public var targetBytes: Int
    /// `heic` or `jpeg`.
    public var format: String

    public init(sourcePath: String, destinationPath: String, targetBytes: Int, format: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.targetBytes = targetBytes
        self.format = format
    }
}

/// What came back from a compression.
public struct CompressResponse: Codable, Sendable, Hashable {
    public var path: String
    public var originalBytes: Int
    public var compressedBytes: Int
    /// The quality the search settled on, for the badge's tooltip.
    public var quality: Double

    public init(path: String, originalBytes: Int, compressedBytes: Int, quality: Double) {
        self.path = path
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
        self.quality = quality
    }

    /// How much smaller, as a fraction. Negative when the result is larger, which happens
    /// to flat screenshots and is worth saying rather than hiding.
    public var savingsFraction: Double {
        guard originalBytes > 0 else { return 0 }
        return 1 - Double(compressedBytes) / Double(originalBytes)
    }

    public var isWorthwhile: Bool {
        compressedBytes < originalBytes
    }
}
