import CoreGraphics
import Foundation

// The wire contract between the agent and the Vision helper (docs/04 §1).
//
// This lives in `Shared` rather than in VisionServices for a specific reason: the agent
// must never link VisionServices — that is the whole point of putting Vision in a
// self-terminating helper, and `Scripts/check-layering.sh` enforces it. But the agent
// still has to name the protocol it is calling. So the *contract* is shared and the
// *implementation*, along with every Vision model it loads, stays in the helper.

/// What to ask the recogniser for (docs/03 §1.7).
public struct TextRecognitionOptions: Codable, Sendable, Hashable {
    /// Keep the line structure, or fold it into spaces (docs/03 §1.7).
    public var preservesLineBreaks: Bool
    /// `nil` lets Vision detect the language itself, which is the default.
    public var languages: [String]?
    /// Also look for QR codes and barcodes.
    public var detectsCodes: Bool

    public init(preservesLineBreaks: Bool = true, languages: [String]? = nil, detectsCodes: Bool = true) {
        self.preservesLineBreaks = preservesLineBreaks
        self.languages = languages
        self.detectsCodes = detectsCodes
    }
}

/// One recognised line.
public struct RecognizedLine: Codable, Sendable, Hashable {
    public let text: String
    public let confidence: Double
    /// Normalised to the image, origin bottom-left — Vision's own convention.
    public let boundingBox: CGRect

    public init(text: String, confidence: Double, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// A decoded QR code or barcode (docs/03 §1.7).
public struct DetectedCode: Codable, Sendable, Hashable {
    public let payload: String
    public let symbology: String
    public let boundingBox: CGRect

    public init(payload: String, symbology: String, boundingBox: CGRect) {
        self.payload = payload
        self.symbology = symbology
        self.boundingBox = boundingBox
    }

    /// A payload that looks like something the user could open.
    public var url: URL? {
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased() else { return nil }
        // Deliberately narrow: a QR code is untrusted input, and offering to open an
        // arbitrary scheme from one is a way to get a user to launch something nasty.
        return ["http", "https", "mailto", "tel"].contains(scheme) ? url : nil
    }
}

/// What the helper sends back.
public struct VisionAnalysis: Codable, Sendable, Hashable {
    public let lines: [RecognizedLine]
    public let codes: [DetectedCode]

    public init(lines: [RecognizedLine] = [], codes: [DetectedCode] = []) {
        self.lines = lines
        self.codes = codes
    }

    public var isEmpty: Bool {
        lines.isEmpty && codes.isEmpty
    }

    /// The recognised text, assembled per the caller's line-break preference.
    public func text(preservingLineBreaks: Bool) -> String {
        let separator = preservingLineBreaks ? "\n" : " "
        return lines.map(\.text).joined(separator: separator)
    }

    public var averageConfidence: Double {
        guard !lines.isEmpty else { return 0 }
        return lines.map(\.confidence).reduce(0, +) / Double(lines.count)
    }
}

/// The XPC interface the helper vends.
///
/// `@objc` because `NSXPCConnection` requires it, and JSON on both sides because encoding
/// Codable values by hand is far less fragile than teaching `NSSecureCoding` about every
/// result type.
@objc
public protocol VisionServiceProtocol {
    /// - Parameters:
    ///   - imageData: the capture, as PNG. The helper only ever receives pixels; every
    ///     ScreenCaptureKit call stays in the agent so the TCC grant attaches there
    ///     (docs/04 §1).
    ///   - optionsData: a JSON-encoded `TextRecognitionOptions`.
    ///   - reply: a JSON-encoded `VisionAnalysis`, or an error.
    func analyze(
        imageData: Data,
        optionsData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )
}

/// The service name the helper listens on and the agent connects to.
public enum VisionServiceName {
    public static let machServiceName = "app.kadr.Kadr.HelperTools"
    /// How long the helper stays alive with nothing to do (docs/04 §1).
    public static let idleTimeout: TimeInterval = 30
}

/// Errors the helper can report back.
public enum VisionServiceError: Int, Error, Sendable, Codable {
    case couldNotDecodeImage = 1
    case recognitionFailed = 2
    case invalidRequest = 3

    public var localizedDescription: String {
        switch self {
        case .couldNotDecodeImage: "Kadr could not read the captured image."
        case .recognitionFailed: "Text recognition failed."
        case .invalidRequest: "The text recognition request was malformed."
        }
    }
}
