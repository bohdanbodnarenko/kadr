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
    /// Run the secret scanner on recognised lines and return boxed candidates (docs/06 M18).
    ///
    /// Off by default: OCR for the capture-text hotkey must stay cheap, and auto-redaction
    /// is a lazy editor action, not something that runs on every capture.
    public var includeRedactionCandidates: Bool
    /// Also look for tables, so a screenshot of one can be pasted as a grid
    /// (macOS 15+, docs/06 M25).
    ///
    /// On by default for Capture Text: it is the same document pass, and finding nothing
    /// costs a check rather than a second recognition.
    public var detectsTables: Bool

    public init(
        preservesLineBreaks: Bool = true,
        languages: [String]? = nil,
        detectsCodes: Bool = true,
        includeRedactionCandidates: Bool = false,
        detectsTables: Bool = true
    ) {
        self.preservesLineBreaks = preservesLineBreaks
        self.languages = languages
        self.detectsCodes = detectsCodes
        self.includeRedactionCandidates = includeRedactionCandidates
        self.detectsTables = detectsTables
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
    /// Secret-shaped spans, boxed in annotation space. Empty unless the caller asked.
    public let candidates: [RedactionCandidate]
    /// Tables found in the capture (macOS 15+, docs/06 M25). Empty on macOS 14, and empty
    /// when the capture is not of a table.
    public let tables: [RecognizedTable]

    public init(
        lines: [RecognizedLine] = [],
        codes: [DetectedCode] = [],
        candidates: [RedactionCandidate] = [],
        tables: [RecognizedTable] = []
    ) {
        self.lines = lines
        self.codes = codes
        self.candidates = candidates
        self.tables = tables
    }

    /// The best table found, if any is worth offering.
    public var primaryTable: RecognizedTable? {
        tables.filter(\.isMeaningful).max { $0.rowCount * $0.columnCount < $1.rowCount * $1.columnCount }
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

    enum CodingKeys: String, CodingKey {
        case lines, codes, candidates, tables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decode([RecognizedLine].self, forKey: .lines)
        codes = try container.decodeIfPresent([DetectedCode].self, forKey: .codes) ?? []
        candidates = try container.decodeIfPresent([RedactionCandidate].self, forKey: .candidates) ?? []
        tables = try container.decodeIfPresent([RecognizedTable].self, forKey: .tables) ?? []
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
    /// The frame rate the encode will use, which may be below the one asked for.
    ///
    /// A GIF destination holds every frame until it is finalised, so a long recording has
    /// to be planned down to fit memory. The plan travels back with the estimate so the
    /// user is asked about the GIF they will actually get, rather than the one they asked
    /// for (docs/07 M10).
    public var frameRate: Int
    public var maximumWidth: Int
    /// How many seconds of the recording the GIF covers.
    public var encodedSeconds: Double
    /// How long the recording is.
    public var sourceSeconds: Double

    /// Whether the GIF stops before the recording does.
    public var isClipped: Bool {
        encodedSeconds + 0.01 < sourceSeconds
    }

    public init(
        path: String?,
        byteCount: Int,
        frameRate: Int = 0,
        maximumWidth: Int = 0,
        encodedSeconds: Double = 0,
        sourceSeconds: Double = 0
    ) {
        self.frameRate = frameRate
        self.maximumWidth = maximumWidth
        self.encodedSeconds = encodedSeconds
        self.sourceSeconds = sourceSeconds
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

/// One capture to read for the history index (docs/03 §5 P3, docs/06 M20).
public struct HistoryIndexItem: Codable, Sendable, Hashable {
    public var id: UUID
    /// The file to recognise text in.
    public var path: String

    public init(id: UUID, path: String) {
        self.id = id
        self.path = path
    }
}

/// A batch of captures to read (docs/03 §5 P3, docs/06 M20).
///
/// Paths in, text out. The helper does the part that needs Vision and nothing else: the
/// library — the SQLite file, the retention policy, the writes — stays with the agent,
/// which owns it and is its only writer (docs/04 §9). Sending the *work* rather than the
/// *database* also keeps the helper small: it has no reason to link a database library
/// it would use for one statement.
public struct HistoryIndexRequest: Codable, Sendable, Hashable {
    public var items: [HistoryIndexItem]

    public init(items: [HistoryIndexItem]) {
        self.items = items
    }
}

/// What one capture said.
public struct HistoryIndexResult: Codable, Sendable, Hashable {
    public var id: UUID
    /// The recognised text. Empty is a real answer — a screenshot of a photo has none —
    /// and the caller still records it so the capture is not read again on every pass.
    public var text: String

    public init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

/// What one indexing pass got through.
public struct HistoryIndexResponse: Codable, Sendable, Hashable {
    public var results: [HistoryIndexResult]

    public init(results: [HistoryIndexResult] = []) {
        self.results = results
    }

    public var isEmpty: Bool {
        results.isEmpty
    }
}

/// Ask Vision which pixels are the subject (docs/04 §6, docs/06 M23).
///
/// Paths rather than pixels, like the GIF and stitch requests: the image is a full-size
/// capture and the mask is another one, and moving both across XPC would cost more than
/// the segmentation.
public struct SubjectMaskRequest: Codable, Sendable, Hashable {
    public var sourcePath: String
    /// Where to write the grayscale mask, at the source's pixel size.
    public var destinationPath: String

    public init(sourcePath: String, destinationPath: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

/// What came back from a subject-mask request.
public struct SubjectMaskResponse: Codable, Sendable, Hashable {
    /// The mask on disk, or nil when the picture has no subject in it.
    public var maskPath: String?
    /// How many separate subjects Vision found. Zero is a normal answer, not an error —
    /// a screenshot of a spreadsheet has no subject, and the editor should say so rather
    /// than show a failure.
    public var subjectCount: Int

    public init(maskPath: String?, subjectCount: Int) {
        self.maskPath = maskPath
        self.subjectCount = subjectCount
    }

    public var isEmpty: Bool {
        subjectCount == 0 || maskPath == nil
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

    /// Re-encodes a capture smaller (docs/09 U2.4).
    ///
    /// In the helper because a compression decodes the capture and encodes it several
    /// times over while it searches for a size — exactly the memory the agent must not be
    /// spending (docs/04 §1, §7 rule 4).
    func compressImage(
        requestData: Data,
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

    /// Reads a batch of captures for the history index (docs/03 §5 P3).
    ///
    /// In the helper because it is OCR, and OCR means Vision models: tens of megabytes
    /// that the agent must never load, and that should die with a process rather than
    /// linger in a menu bar app (docs/04 §1, §7 rule 4). Only the recognition happens
    /// here — the agent stays the single writer of the library (docs/04 §9) — and it only
    /// asks for a pass when the machine is on mains power and the user opted in, so the
    /// library getting indexed costs the idle budget exactly nothing.
    func indexHistory(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// Segments the subject out of a capture and writes a mask (docs/04 §6, docs/06 M23).
    ///
    /// In the helper because it is Vision: the segmentation model is tens of megabytes,
    /// the editor must not load it, and process exit is the only thing that reliably gives
    /// it back (docs/04 §1, §7 rule 4).
    func subjectMask(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// Transcribes a recording's audio, in the helper (docs/13 T1.1).
    ///
    /// Paths rather than samples: a 45-minute recording is hundreds of megabytes, and the
    /// point of doing this in the helper is that Speech's models and decode buffers die
    /// with a process rather than lingering in the editor or the agent.
    func transcribe(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// Whether a language can be transcribed, without downloading anything.
    func speechStatus(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// Downloads the on-device model, only when a person pressed the button that says so.
    func installSpeechModel(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// Stops a transcription or a model download that is still running.
    func cancelSpeech()

    /// Prepares the speech engine so the first tidy is not a cold start (docs/13 T1.5).
    func warmUpSpeech(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// Starts live recognition for the teleprompter (docs/13 T2.1).
    func startLiveSpeech(
        requestData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    )

    /// PCM Int16 16 kHz mono, one chunk.
    func feedLiveSpeechAudio(_ pcmData: Data)

    func stopLiveSpeech()
}

/// The service name the helper listens on. Prefixed by both host apps
/// (`app.kadr.Kadr` and `app.kadr.Kadr.Editor`) so the same XPC can live in
/// either bundle without rewriting its Info.plist after copy.
public enum VisionServiceName {
    public static let machServiceName = "app.kadr.Kadr.Editor.HelperTools"

    /// How long the helper stays alive with nothing to do (docs/04 §1).
    public static let idleTimeout: TimeInterval = 30
}
