import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
@testable import VisionServices

/// Ten secrets, one per line — the M18 "seeded test images" fixture (docs/06).
private enum SeededSecrets {
    static let all: [(kind: SecretKind, text: String)] = [
        (.email, "user@example.com"),
        (.email, "first.last@company.co.uk"),
        (.phone, "+1 (415) 555-2671"),
        (.phone, "020 7946 0958"),
        (.creditCard, "4111111111111111"),
        (.creditCard, "5500000000000004"),
        (.iban, "DE89370400440532013000"),
        (.jwt, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"),
        (.apiKey, "sk_live_51FakeTestKeyWithHighEntropyXX"),
        (.apiKey, "AKIAIOSFODNN7EXAMPLE")
    ]
}

private func makeMultilineImage(_ lines: [String], width: Int = 1800, lineHeight: Int = 44) -> Data {
    let height = max(lineHeight * lines.count + 40, 80)
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

    let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
    let color = CGColor(gray: 0, alpha: 1)
    for (index, string) in lines.enumerated() {
        let attributed = NSAttributedString(string: string, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        // Core Text y is bottom-left; draw from the top down.
        let y = CGFloat(height - 36 - index * lineHeight)
        context.textPosition = CGPoint(x: 16, y: y)
        CTLineDraw(line, context)
    }

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

@Suite("Auto-redaction candidates")
struct RedactionCandidateTests {
    private let recognizer = TextRecognizer()

    @Test("Seeded secrets are all proposed at review and never auto-applied")
    func seededSecretsReachReview() async throws {
        let png = makeMultilineImage(SeededSecrets.all.map(\.text))
        let analysis = try await recognizer.analyze(
            pngData: png,
            options: TextRecognitionOptions(
                detectsCodes: false,
                includeRedactionCandidates: true
            )
        )

        // Review stage: every seeded secret is a candidate. The helper does not mutate
        // pixels — there is nothing here that "applies" a blur.
        #expect(analysis.candidates.count >= SeededSecrets.all.count)

        for secret in SeededSecrets.all {
            let hit = analysis.candidates.first { candidate in
                candidate.kind == secret.kind && reviewMatch(candidate.text, secret.text, kind: secret.kind)
            }
            #expect(
                hit != nil,
                "missed \(secret.kind.rawValue) \(secret.text); OCR: \(analysis.text(preservingLineBreaks: true))"
            )
            if let hit {
                #expect(hit.boundingBox.width > 0)
                #expect(hit.boundingBox.height > 0)
            }
        }
    }

    @Test("Candidates are not produced unless the caller asked")
    func lazyByDefault() async throws {
        let png = makeMultilineImage(["user@example.com"])
        let analysis = try await recognizer.analyze(
            pngData: png,
            options: TextRecognitionOptions(detectsCodes: false)
        )
        #expect(analysis.candidates.isEmpty)
        #expect(!analysis.lines.isEmpty)
    }
}

private func looselyContains(_ haystack: String, _ needle: String) -> Bool {
    let foldedHay = haystack.filter { !$0.isWhitespace && $0 != "-" }
    let foldedNeedle = needle.filter { !$0.isWhitespace && $0 != "-" }
    return haystack.localizedCaseInsensitiveContains(needle)
        || foldedHay.localizedCaseInsensitiveContains(foldedNeedle)
}

/// JWTs are the OCR pain case: Vision substitutes lookalikes. A candidate that is still
/// a three-segment `eyJ…` token counts as the seeded JWT at review.
private func reviewMatch(_ haystack: String, _ needle: String, kind: SecretKind) -> Bool {
    if looselyContains(haystack, needle) {
        return true
    }
    return kind == .jwt && haystack.hasPrefix("eyJ") && haystack.filter { $0 == "." }.count >= 2
}
