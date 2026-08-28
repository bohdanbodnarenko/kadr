import CoreGraphics
import Foundation

/// What replaces the background once the subject is lifted (docs/03 §3 P3, docs/06 M23).
public enum SubjectLiftBackground: Codable, Hashable, Sendable {
    /// Real transparency, which is what a cut-out is for. Export falls back to PNG when
    /// the chosen format cannot carry alpha.
    case transparent
    case color(AnnotationColor)

    public var color: AnnotationColor? {
        if case let .color(value) = self {
            return value
        }
        return nil
    }
}

/// Background removal (docs/03 §3 P3, docs/06 M23).
///
/// Canvas chrome rather than an object on the canvas: it changes what the base image *is*,
/// like a crop does, so it is edited through its own control and cannot be selected and
/// dragged around.
///
/// The mask travels inside the document as a PNG. That keeps a `.kadr` file self-contained
/// — reopening a project on another machine must not depend on a scratch file that was
/// swept away — and a segmentation mask is mostly flat, so it compresses to a fraction of
/// the capture it came from.
public struct SubjectLiftSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    /// A grayscale PNG at the base image's pixel size. White is subject.
    public var maskPNG: Data
    public var background: SubjectLiftBackground

    public init(
        id: AnnotationID = AnnotationID(),
        maskPNG: Data,
        background: SubjectLiftBackground = .transparent
    ) {
        self.id = id
        self.maskPNG = maskPNG
        self.background = background
    }

    /// Whether the export has to keep an alpha channel.
    public var needsTransparency: Bool {
        background == .transparent
    }
}
