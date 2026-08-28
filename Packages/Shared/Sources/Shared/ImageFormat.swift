import CoreGraphics
import UniformTypeIdentifiers

/// Still-image export formats (docs/03 §8.3, PRD §5 Phase 1).
///
/// In `Shared` rather than in MediaExport or SettingsKit because both need it and they
/// are sibling layers that cannot import one another (docs/04 §2).
public enum ImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case heic
    case webp

    public var fileExtension: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
        }
    }

    /// The type ImageIO writes for this format.
    public var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .webp: .webP
        }
    }

    /// Whether the format keeps an alpha channel.
    ///
    /// Matters for window capture: exporting a transparent window as JPEG silently
    /// composites it onto black, which looks like a bug to the user (docs/03 §1.2).
    public var supportsTransparency: Bool {
        switch self {
        case .png, .heic, .webp: true
        case .jpeg: false
        }
    }

    /// Whether the format can carry more than 8 bits per channel.
    ///
    /// Matters for HDR (docs/06 M25): an HDR capture written as JPEG is quantised to 8
    /// bits and tone-mapped on the way, which throws away the entire point of having
    /// captured it in HDR. PNG carries 16-bit channels and an ICC profile; HEIC is the
    /// format actually designed for this.
    public var supportsHighBitDepth: Bool {
        switch self {
        case .png, .heic: true
        case .jpeg, .webp: false
        }
    }

    /// Whether a quality setting means anything.
    public var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .webp: true
        case .png: false
        }
    }
}
