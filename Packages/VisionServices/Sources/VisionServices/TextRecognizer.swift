import CoreGraphics
import Foundation
import ImageIO
import os
import Shared
import Vision

/// On-device text and barcode recognition (docs/03 §1.7).
///
/// Lives in the helper process and nowhere else. Vision's models are tens of megabytes
/// once loaded, and the only reliable way to give that memory back is to let the process
/// exit — which is exactly what the helper does after 30 s idle (docs/04 §1, §7 rule 4).
///
/// Everything here is on-device. There is no network path in this package, and CI checks
/// that (`Scripts/check-layering.sh`).
public struct TextRecognizer: Sendable {
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    public init() {}

    /// Recognises text and codes in a PNG.
    public func analyze(pngData: Data, options: TextRecognitionOptions) async throws -> VisionAnalysis {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw VisionServiceError.couldNotDecodeImage
        }
        return try await analyze(image: image, options: options)
    }

    public func analyze(image: CGImage, options: TextRecognitionOptions) async throws -> VisionAnalysis {
        let state = signposter.beginInterval("visionAnalyze")
        defer { signposter.endInterval("visionAnalyze", state) }

        async let pass = recognizeText(in: image, options: options)
        async let codes = options.detectsCodes ? detectCodes(in: image) : []
        // Concurrent with the rest: it is a second pass over the same pixels, and making
        // Capture Text wait for it in series would double the latency budget (docs/03 §1.7).
        async let tables = options.detectsTables ? DocumentTableRecognizer().tables(in: image) : []

        let text = try await pass
        return try await VisionAnalysis(
            lines: text.lines,
            codes: codes,
            candidates: text.candidates,
            tables: tables,
            words: text.words
        )
    }

    // MARK: - Text

    private struct TextPass: Sendable {
        var lines: [RecognizedLine]
        var candidates: [RedactionCandidate]
        var words: [RecognizedWord]
    }

    private func recognizeText(
        in image: CGImage,
        options: TextRecognitionOptions
    ) async throws -> TextPass {
        let request = VNRecognizeTextRequest()
        // Accurate rather than fast: this is a user asking for the text in a screenshot,
        // not a real-time video pass (docs/03 §1.7).
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages = options.languages, !languages.isEmpty {
            request.recognitionLanguages = languages
        } else {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            throw VisionServiceError.recognitionFailed
        }

        let observations = request.results ?? []
        var lines: [RecognizedLine] = []
        var candidates: [RedactionCandidate] = []
        var words: [RecognizedWord] = []
        lines.reserveCapacity(observations.count)
        words.reserveCapacity(observations.count)

        let redactionState = options.includeRedactionCandidates
            ? signposter.beginInterval("redactionDetect")
            : nil
        defer {
            if let redactionState {
                signposter.endInterval("redactionDetect", redactionState)
            }
        }

        for observation in observations {
            guard let recognized = observation.topCandidates(1).first else { continue }
            lines.append(RecognizedLine(
                text: recognized.string,
                confidence: Double(recognized.confidence),
                boundingBox: observation.boundingBox
            ))
            words.append(contentsOf: Self.words(from: recognized, observation: observation))
            if options.includeRedactionCandidates {
                candidates.append(contentsOf: Self.candidates(from: recognized, observation: observation))
            }
        }

        if options.includeRedactionCandidates {
            candidates.append(contentsOf: Self.unboxedMatches(in: lines, already: candidates))
        }

        return TextPass(lines: lines, candidates: candidates, words: words)
    }

    /// Word boxes in annotation space. The highlighter snaps to these (docs/03 §3 P2).
    private static func words(
        from recognized: VNRecognizedText,
        observation: VNRecognizedTextObservation
    ) -> [RecognizedWord] {
        var boxes: [RecognizedWord] = []
        recognized.string.enumerateSubstrings(
            in: recognized.string.startIndex...,
            options: .byWords
        ) { substring, range, _, _ in
            guard let substring, !substring.isEmpty else { return }
            let visionBox = substringBox(
                of: recognized,
                range: NSRange(range, in: recognized.string),
                fallback: observation.boundingBox
            )
            boxes.append(RecognizedWord(
                text: substring,
                boundingBox: VisionNormalizedBox.topLeft(fromVision: visionBox)
            ))
        }
        if boxes.isEmpty, !recognized.string.isEmpty {
            boxes.append(RecognizedWord(
                text: recognized.string,
                boundingBox: VisionNormalizedBox.topLeft(fromVision: observation.boundingBox)
            ))
        }
        return boxes
    }

    /// Secrets that only appear once the lines are joined — a JWT OCR'd as two lines, for
    /// example. Uses the line box as a stand-in when Vision has no substring quad.
    private static func unboxedMatches(
        in lines: [RecognizedLine],
        already: [RedactionCandidate]
    ) -> [RedactionCandidate] {
        let blob = lines.map(\.text).joined(separator: "\n")
        return SecretScanner.matches(in: blob).compactMap { match in
            let folded = match.text.filter { !$0.isWhitespace && $0 != "-" }
            let exists = already.contains { candidate in
                candidate.kind == match.kind
                    && candidate.text.filter { !$0.isWhitespace && $0 != "-" } == folded
            }
            guard !exists else { return nil }
            let prefix = String(match.text.prefix(12))
            let line = lines.first { $0.text.localizedCaseInsensitiveContains(prefix) }
            let visionBox = line?.boundingBox ?? lines.first?.boundingBox ?? .zero
            return RedactionCandidate(
                kind: match.kind,
                text: match.text,
                boundingBox: VisionNormalizedBox.topLeft(fromVision: visionBox)
            )
        }
    }

    /// Boxes each secret inside a recognised line using Vision's substring quads.
    ///
    /// This is the only place Vision types meet the scanner: the editor receives
    /// `RedactionCandidate` values and never imports this package.
    private static func candidates(
        from recognized: VNRecognizedText,
        observation: VNRecognizedTextObservation
    ) -> [RedactionCandidate] {
        SecretScanner.matches(in: recognized.string).map { match in
            RedactionCandidate(
                kind: match.kind,
                text: match.text,
                boundingBox: VisionNormalizedBox.topLeft(
                    fromVision: substringBox(of: recognized, range: match.nsRange, fallback: observation.boundingBox)
                )
            )
        }
    }

    private static func substringBox(
        of recognized: VNRecognizedText,
        range: NSRange,
        fallback: CGRect
    ) -> CGRect {
        guard let swiftRange = Range(range, in: recognized.string),
              let quad = try? recognized.boundingBox(for: swiftRange)
        else {
            return fallback
        }
        return quad.boundingBox
    }

    // MARK: - Codes

    private func detectCodes(in image: CGImage) async throws -> [DetectedCode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A capture with no barcode is the common case, and a barcode pass that fails
            // must not lose the text the user actually asked for.
            logger.info("Barcode detection failed; continuing with text only")
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue else { return nil }
            return DetectedCode(
                payload: payload,
                symbology: observation.symbology.rawValue,
                boundingBox: observation.boundingBox
            )
        }
    }
}
