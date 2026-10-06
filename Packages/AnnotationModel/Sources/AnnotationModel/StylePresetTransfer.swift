import Foundation

/// A look that can be handed to someone else (docs/10 R3.5).
///
/// Deliberately not the storage model. `StylePreset` may name a local wallpaper; a file
/// that travels cannot, because the path would be meaningless on another Mac and a
/// wallpaper packed into the file would be a size we do not want to carry. Local image
/// backdrops are replaced with a solid fill before encoding.
///
/// Size-capped so a malformed or hostile file cannot be an unbounded decode.
public struct StylePresetTransfer: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    public static let pathExtension = "kadrpreset"
    public static let typeIdentifier = "com.bohdanbodnarenko.kadr.preset"
    public static let maximumByteCount = 256 * 1024

    public var version: Int
    public var preset: StylePreset

    public enum TransferError: Error, Equatable, Sendable {
        case tooLarge
    }

    public init(preset: StylePreset) {
        version = Self.currentVersion
        self.preset = Self.strippingLocalPaths(preset)
    }

    /// Encodes this transfer, refusing to emit more than `maximumByteCount` bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumByteCount else { throw TransferError.tooLarge }
        return data
    }

    /// Decodes a transfer, stripping local paths again in case an older writer packed one.
    public static func decoding(_ data: Data) throws -> StylePreset {
        guard data.count <= maximumByteCount else { throw TransferError.tooLarge }
        let transfer = try JSONDecoder().decode(Self.self, from: data)
        return strippingLocalPaths(transfer.preset).sanitized()
    }

    /// Replaces a local wallpaper with a solid fill so the look can travel.
    public static func strippingLocalPaths(_ preset: StylePreset) -> StylePreset {
        var copy = preset
        if case .image = copy.beautify?.backdrop {
            copy.beautify?.backdrop = .solid(.black)
        }
        return copy
    }
}
