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

/// How a GIF should be encoded. Mirrors MediaExport's own options across the wire,
/// because the agent cannot import MediaExport's encoder without doing the work itself.
public struct GIFRequest: Codable, Sendable, Hashable {
    public var sourcePath: String
    public var destinationPath: String
    public var frameRate: Int
    public var maximumWidth: Int
    /// Measure rather than encode, for the size shown before committing (docs/03 §1.8).
    public var estimateOnly: Bool

    public init(
        sourcePath: String,
        destinationPath: String,
        frameRate: Int = 15,
        maximumWidth: Int = 800,
        estimateOnly: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.frameRate = frameRate
        self.maximumWidth = maximumWidth
        self.estimateOnly = estimateOnly
    }
}

/// What came back from a GIF request.
public struct GIFResponse: Codable, Sendable, Hashable {
    /// Where the GIF was written, or nil for an estimate.
    public var path: String?
    public var byteCount: Int

    public init(path: String?, byteCount: Int) {
        self.path = path
        self.byteCount = byteCount
    }
}

/// A scrolling capture to stitch (docs/03 §1.6).
///
/// Paths, not pixels: a scroll of a long page is a hundred full-screen frames, and moving
/// those across XPC to stitch them would cost more than the stitch. The agent writes them
/// to a session directory and hands over the directory's contents in order.
public struct ScrollStitchRequest: Codable, Sendable, Hashable {
    /// The captured frames, in the order they were taken.
    public var framePaths: [String]
    public var destinationPath: String
    /// Beyond this many rows the strip is assembled in a memory-mapped scratch file
    /// rather than a heap bitmap, so a 30,000-pixel page does not become 140 MB of RSS
    /// (docs/03 §1.6 accept list).
    public var memoryMappedThreshold: Int
    /// Frames the user asked to leave out after reviewing a bad seam, by index.
    public var excludedFrames: [Int]

    public init(
        framePaths: [String],
        destinationPath: String,
        memoryMappedThreshold: Int = 16000,
        excludedFrames: [Int] = []
    ) {
        self.framePaths = framePaths
        self.destinationPath = destinationPath
        self.memoryMappedThreshold = memoryMappedThreshold
        self.excludedFrames = excludedFrames
    }
}

/// One join between two frames, and how much it should be trusted.
public struct ScrollSeam: Codable, Sendable, Hashable {
    /// The index of the frame joined onto what came before it.
    public var frameIndex: Int
    /// Where the seam falls in the finished image, in pixels from the top.
    public var y: Int
    /// Rows of new content this frame contributed.
    public var offset: Int
    public var confidence: Double

    public init(frameIndex: Int, y: Int, offset: Int, confidence: Double) {
        self.frameIndex = frameIndex
        self.y = y
        self.offset = offset
        self.confidence = confidence
    }

    /// Worth showing the user rather than silently trusting (docs/03 §1.6).
    public var isUncertain: Bool {
        confidence < 0.55
    }
}

/// What came back from a stitch.
public struct ScrollStitchResponse: Codable, Sendable, Hashable {
    public var path: String
    public var pixelSize: PixelSize
    public var seams: [ScrollSeam]
    /// Rows of chrome that stayed put and were kept only once (docs/03 §1.6).
    public var stickyHeader: Int
    public var stickyFooter: Int

    public init(
        path: String,
        pixelSize: PixelSize,
        seams: [ScrollSeam],
        stickyHeader: Int = 0,
        stickyFooter: Int = 0
    ) {
        self.path = path
        self.pixelSize = pixelSize
        self.seams = seams
        self.stickyHeader = stickyHeader
        self.stickyFooter = stickyFooter
    }

    public var uncertainSeams: [ScrollSeam] {
        seams.filter(\.isUncertain)
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

    /// Encodes a recording as a GIF, or estimates its size.
    ///
    /// In the helper because an encode holds the frames it is working on, and that is
    /// exactly the memory the agent must not be spending (docs/04 §1, §7 rule 4). Paths
    /// rather than data: a recording can be hundreds of megabytes, and copying it across
    /// XPC to encode it would be absurd.
    func encodeGIF(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// Stitches a scrolling capture into one tall image (docs/03 §1.6, docs/04 §4.4).
    ///
    /// In the helper for the same reason as the GIF encoder: the stitch holds frames and
    /// a full-page bitmap, and that memory should die with a process rather than linger
    /// in a menu bar app (docs/04 §1, §7 rule 4).
    func stitchScroll(
        requestData: Data,
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
    case stitchFailed = 4
    case notEnoughFrames = 5

    public var localizedDescription: String {
        switch self {
        case .couldNotDecodeImage: "Kadr could not read the captured image."
        case .recognitionFailed: "Text recognition failed."
        case .invalidRequest: "The text recognition request was malformed."
        case .stitchFailed: "Kadr could not stitch the scrolling capture."
        case .notEnoughFrames: "A scrolling capture needs at least two frames."
        }
    }
}
