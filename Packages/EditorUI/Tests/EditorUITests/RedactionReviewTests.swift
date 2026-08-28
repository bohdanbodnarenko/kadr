import AnnotationModel
import CoreGraphics
import Shared
import Testing
@testable import EditorUI

@MainActor
@Suite("Auto-redaction review")
struct RedactionReviewTests {
    @Test("Staging candidates does not write redactions")
    func neverAutoApplies() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let candidate = RedactionCandidate(
            kind: .email,
            text: "user@example.com",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05)
        )
        model.beginRedactionReview(VisionAnalysis(candidates: [candidate]))

        #expect(model.document.commands.isEmpty, "detect must not blur on its own")
        #expect(model.redactionCandidates.count == 1)
        #expect(model.isRedactionReviewActive)
    }

    @Test("Accepting one candidate appends a blur")
    func acceptOneAppendsRedaction() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let candidate = RedactionCandidate(
            kind: .email,
            text: "user@example.com",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05)
        )
        model.beginRedactionReview(VisionAnalysis(candidates: [candidate]))
        model.acceptRedaction(candidate.id)

        #expect(model.document.commands.count == 1)
        #expect(model.redactionCandidates.isEmpty)
        guard case let .redaction(spec) = model.document.commands.first else {
            Issue.record("expected a redaction command")
            return
        }
        #expect(spec.rect.width > 0)
        #expect(spec.rect.height > 0)
        #expect(spec.style == .defaultBlur)
    }

    @Test("Dismissing review leaves the document untouched")
    func dismissDoesNotApply() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let candidate = RedactionCandidate(
            kind: .apiKey,
            text: "AKIAIOSFODNN7EXAMPLE",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.05)
        )
        model.beginRedactionReview(VisionAnalysis(candidates: [candidate]))
        model.dismissRedactionReview()

        #expect(model.document.commands.isEmpty)
        #expect(model.redactionCandidates.isEmpty)
        #expect(!model.isRedactionReviewActive)
    }

    @Test("Accept all appends one redaction per candidate in a single undo step")
    func acceptAllIsOneUndoStep() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let first = RedactionCandidate(
            kind: .email,
            text: "a@b.co",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        )
        let second = RedactionCandidate(
            kind: .phone,
            text: "+1 (415) 555-2671",
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        )
        model.beginRedactionReview(VisionAnalysis(candidates: [first, second]))
        model.acceptAllRedactions()

        #expect(model.document.commands.count == 2)
        #expect(model.redactionCandidates.isEmpty)
        model.undo()
        #expect(model.document.commands.isEmpty, "accept all should be one undo step")
    }

    @Test("The find field stages custom candidates without applying them")
    func findFieldStagesWithoutApplying() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let line = RecognizedLine(
            text: "error from stripe checkout",
            confidence: 1,
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)
        )
        model.beginRedactionReview(VisionAnalysis(lines: [line]))
        #expect(model.document.commands.isEmpty)

        model.redactionQuery = "stripe"
        model.stageQueryMatches()

        #expect(model.document.commands.isEmpty)
        #expect(model.redactionCandidates.count == 1)
        #expect(model.redactionCandidates.first?.kind == .custom)
        #expect(model.redactionCandidates.first?.text.lowercased() == "stripe")
    }

    @Test("Skip drops a candidate without touching the document")
    func skipLeavesDocument() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let candidate = RedactionCandidate(
            kind: .jwt,
            text: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.05)
        )
        model.beginRedactionReview(VisionAnalysis(candidates: [candidate]))
        model.skipRedaction(candidate.id)
        #expect(model.document.commands.isEmpty)
        #expect(model.redactionCandidates.isEmpty)
    }
}
