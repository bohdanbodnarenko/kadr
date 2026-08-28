import CoreGraphics
import Foundation

/// A kind of secret the auto-redaction assistant can propose (docs/03 §3).
///
/// These are *candidates*. The editor never applies a redaction until the user accepts
/// one — auto-detect is a review step, not a silent rewrite.
public enum SecretKind: String, Codable, Sendable, Hashable, CaseIterable {
    case email
    case phone
    case creditCard
    case iban
    case jwt
    case apiKey
    /// A value that a label said was secret — `password: hunter2` — whatever it looks
    /// like. The only detector that catches a weak password, because nothing about
    /// "hunter2" is detectable except the word in front of it (docs/09 U1.6).
    case credential
    /// A user-typed find-field match, not a built-in detector.
    case custom

    public var title: String {
        switch self {
        case .email: "Email"
        case .phone: "Phone number"
        case .creditCard: "Card number"
        case .iban: "IBAN"
        case .jwt: "JWT"
        case .apiKey: "API key"
        case .credential: "Password or token"
        case .custom: "Match"
        }
    }
}

/// One hit inside a recognised string, before it has a box on the image.
public struct SecretMatch: Hashable, Sendable {
    public let kind: SecretKind
    public let text: String
    /// UTF-16 location in the source string (`NSRegularExpression`'s convention).
    public let location: Int
    public let length: Int

    public init(kind: SecretKind, text: String, location: Int, length: Int) {
        self.kind = kind
        self.text = text
        self.location = location
        self.length = length
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

/// A secret the helper wants the editor to *review*, never to apply on its own.
///
/// `boundingBox` is normalised to the image with origin at the **top-left**, matching
/// annotation space. Multiply by the image's point size to get a `RedactionSpec.rect`.
public struct RedactionCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: SecretKind
    public let text: String
    public let boundingBox: CGRect

    public init(
        id: UUID = UUID(),
        kind: SecretKind,
        text: String,
        boundingBox: CGRect
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.boundingBox = boundingBox
    }

    /// Image-space rect, padded so the blur covers glyph overhang, then clamped.
    public func rect(in imageSize: CGSize, padding: CGFloat = 3) -> CGRect {
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

/// Vision reports boxes with origin at the bottom-left. Annotation space is top-left.
public enum VisionNormalizedBox {
    /// Converts a Vision-normalised box (origin bottom-left) into annotation space.
    public static func topLeft(fromVision box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Approximate a substring box from a whole-line Vision box.
    ///
    /// Used by the editor find field, which only has line observations — not Vision's
    /// per-character quads, which stay in the helper.
    public static func proportionalTopLeft(
        visionLineBox: CGRect,
        text: String,
        utf16Range: NSRange
    ) -> CGRect {
        let topLeft = topLeft(fromVision: visionLineBox)
        let length = (text as NSString).length
        guard length > 0, utf16Range.location >= 0, utf16Range.length > 0 else { return topLeft }
        let start = min(CGFloat(utf16Range.location) / CGFloat(length), 1)
        let width = min(CGFloat(utf16Range.length) / CGFloat(length), 1 - start)
        return CGRect(
            x: topLeft.minX + topLeft.width * start,
            y: topLeft.minY,
            width: topLeft.width * width,
            height: topLeft.height
        )
    }
}
