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

        async let lines = recognizeText(in: image, options: options)
        async let codes = options.detectsCodes ? detectCodes(in: image) : []

        return try await VisionAnalysis(lines: lines, codes: codes)
    }

    // MARK: - Text

    private func recognizeText(
        in image: CGImage,
        options: TextRecognitionOptions
    ) async throws -> [RecognizedLine] {
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
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                boundingBox: observation.boundingBox
            )
        }
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
