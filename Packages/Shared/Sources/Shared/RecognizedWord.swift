import CoreGraphics
import Foundation

/// One recognised word, boxed in annotation space (top-left origin).
///
/// Distinct from `RecognizedLine`, whose box stays in Vision's bottom-left convention so
/// existing OCR and find-field code does not have to change. The editor's smart highlighter
/// needs word boxes in the same space it draws in (docs/03 §3 P2).
public struct RecognizedWord: Codable, Sendable, Hashable {
    public let text: String
    /// Normalised to the image, origin top-left — the same as `RedactionCandidate`.
    public let boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }

    /// Image-space rect, padded so a click just outside a glyph still snaps.
    public func rect(in imageSize: CGSize, padding: CGFloat = 2) -> CGRect {
        let raw = CGRect(
            x: boundingBox.minX * imageSize.width,
            y: boundingBox.minY * imageSize.height,
            width: boundingBox.width * imageSize.width,
            height: boundingBox.height * imageSize.height
        )
        let padded = raw.insetBy(dx: -padding, dy: -padding)
        let minX = max(0, padded.minX)
        let minY = max(0, padded.minY)
        let maxX = min(imageSize.width, padded.maxX)
        let maxY = min(imageSize.height, padded.maxY)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

public extension VisionAnalysis {
    /// Word boxes in image space, falling back to whole lines when the helper is older.
    func highlightBoxes(in imageSize: CGSize) -> [CGRect] {
        if !words.isEmpty {
            return words.map { $0.rect(in: imageSize) }
        }
        return lines.map { line in
            let box = VisionNormalizedBox.topLeft(fromVision: line.boundingBox)
            return CGRect(
                x: box.minX * imageSize.width,
                y: box.minY * imageSize.height,
                width: box.width * imageSize.width,
                height: box.height * imageSize.height
            )
        }
    }
}
