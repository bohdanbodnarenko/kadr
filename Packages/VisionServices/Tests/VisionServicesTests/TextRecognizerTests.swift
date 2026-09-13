import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
@testable import VisionServices

/// Renders text into a PNG, so recognition has something real to read.
private func makeTextImage(_ string: String, width: Int = 600, height: Int = 160) -> Data {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
    let attributed = NSAttributedString(string: string, attributes: [
        .init(kCTFontAttributeName as String): font,
        .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 20, y: 60)
    CTLineDraw(line, context)

    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Could not create a test image destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not encode the test image")
    }
    return data as Data
}

@Suite("Text recognition")
struct TextRecognizerTests {
    private let recognizer = TextRecognizer()

    @Test("Rendered text is read back")
    func recognisesText() async throws {
        let analysis = try await recognizer.analyze(
            pngData: makeTextImage("Hello Kadr"),
            options: TextRecognitionOptions()
        )

        let text = analysis.text(preservingLineBreaks: true)
        #expect(text.localizedCaseInsensitiveContains("Kadr"), "read back \(text.debugDescription)")
        #expect(analysis.averageConfidence > 0.3)
    }

    @Test("A blank image yields nothing rather than noise")
    func blankImage() async throws {
        let analysis = try await recognizer.analyze(
            pngData: makeTextImage(""),
            options: TextRecognitionOptions()
        )
        #expect(analysis.lines.isEmpty)
        #expect(analysis.isEmpty)
    }

    @Test("Bytes that are not an image are refused")
    func refusesNonImages() async {
        await #expect(throws: VisionServiceError.couldNotDecodeImage) {
            try await recognizer.analyze(pngData: Data("not a png".utf8), options: TextRecognitionOptions())
        }
    }

    @Test("Recognition can skip the barcode pass")
    func skipsCodesWhenAsked() async throws {
        let analysis = try await recognizer.analyze(
            pngData: makeTextImage("Text only"),
            options: TextRecognitionOptions(detectsCodes: false)
        )
        #expect(analysis.codes.isEmpty)
        #expect(analysis.candidates.isEmpty, "redaction candidates are opt-in")
    }

    @Test("Word boxes travel with recognised lines")
    func wordBoxes() async throws {
        let analysis = try await recognizer.analyze(
            pngData: makeTextImage("Hello Kadr"),
            options: TextRecognitionOptions(detectsCodes: false, detectsTables: false)
        )
        guard !analysis.lines.isEmpty else { return }
        #expect(!analysis.words.isEmpty, "a line Vision could read should produce word boxes")
        #expect(analysis.words.allSatisfy { $0.boundingBox.width > 0 && $0.boundingBox.height > 0 })
    }

    @Test("Redaction candidates stay off unless asked")
    func redactionCandidatesAreLazy() async throws {
        let analysis = try await recognizer.analyze(
            pngData: makeTextImage("user@example.com"),
            options: TextRecognitionOptions(detectsCodes: false)
        )
        #expect(analysis.candidates.isEmpty)
    }
}

@Suite("Vision result shaping")
struct VisionAnalysisTests {
    private let lines = [
        RecognizedLine(text: "first", confidence: 0.9, boundingBox: .zero),
        RecognizedLine(text: "second", confidence: 0.7, boundingBox: .zero)
    ]

    @Test("Line breaks are preserved or folded, per the setting")
    func lineBreakHandling() {
        let analysis = VisionAnalysis(lines: lines)
        #expect(analysis.text(preservingLineBreaks: true) == "first\nsecond")
        #expect(analysis.text(preservingLineBreaks: false) == "first second")
    }

    @Test("Confidence is averaged across lines")
    func confidence() {
        #expect(abs(VisionAnalysis(lines: lines).averageConfidence - 0.8) < 0.0001)
        #expect(VisionAnalysis().averageConfidence == 0)
    }

    @Test("Only web and contact schemes are offered as openable links")
    func openableSchemes() {
        /// A QR code is untrusted input: offering to open an arbitrary scheme from one is
        /// a way to get a user to launch something they did not intend.
        func code(_ payload: String) -> DetectedCode {
            DetectedCode(payload: payload, symbology: "QR", boundingBox: .zero)
        }
        #expect(code("https://example.com").url != nil)
        #expect(code("mailto:a@example.com").url != nil)
        #expect(code("tel:+123").url != nil)
        #expect(code("file:///etc/passwd").url == nil)
        #expect(code("javascript:alert(1)").url == nil)
        #expect(code("just some text").url == nil)
    }

    @Test("The analysis round-trips through JSON, which is how it crosses XPC")
    func codable() throws {
        let analysis = VisionAnalysis(
            lines: lines,
            codes: [DetectedCode(payload: "x", symbology: "QR", boundingBox: .zero)],
            words: [RecognizedWord(text: "first", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))]
        )
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(VisionAnalysis.self, from: data)
        #expect(decoded == analysis)
        #expect(decoded.candidates.isEmpty)
    }

    @Test("JSON without words still decodes")
    func decodesWithoutWords() throws {
        let json = Data(#"{"lines":[],"codes":[]}"#.utf8)
        let analysis = try JSONDecoder().decode(VisionAnalysis.self, from: json)
        #expect(analysis.words.isEmpty)
    }

    @Test("Options round-trip too")
    func optionsCodable() throws {
        let options = TextRecognitionOptions(
            preservesLineBreaks: false,
            languages: ["en"],
            detectsCodes: false,
            includeRedactionCandidates: true
        )
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(TextRecognitionOptions.self, from: data) == options)
    }
}
