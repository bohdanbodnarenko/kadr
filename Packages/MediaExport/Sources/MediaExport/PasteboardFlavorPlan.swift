import Foundation
import Shared

/// Clipboard flavours a capture should advertise (docs/16 X-1).
///
/// Terminals and "paste a file" apps read the URL. Gmail, Notes, Slack and Figma read
/// pixels. HEIC and WebP are written natively, with PNG and TIFF as fallbacks so a
/// receiver that cannot decode the native type still pastes something.
public enum PasteboardFlavor: String, Sendable, Hashable, CaseIterable {
    case native
    case pngFallback
    case tiffFallback
    case fileURL
}

public enum PasteboardFlavorPlan: Sendable {
    /// Flavours to put on one pasteboard item, in preference order.
    public static func flavors(for format: ImageFormat, isFinalized: Bool) -> [PasteboardFlavor] {
        var flavors: [PasteboardFlavor] = [.native]
        if format != .png {
            flavors.append(.pngFallback)
        }
        flavors.append(.tiffFallback)
        if isFinalized {
            flavors.append(.fileURL)
        }
        return flavors
    }
}
