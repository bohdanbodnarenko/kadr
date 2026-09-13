import AnnotationModel
import CoreGraphics
import Foundation
import Shared

public extension EditorDocumentModel {
    var hasRedactionReviewChrome: Bool {
        isRedactionReviewActive || isFindingRedactions || redactionAssistError != nil
    }

    func startRedactionSearch() {
        isFindingRedactions = true
        redactionAssistError = nil
    }

    /// Stages helper output for review. Does not append redaction commands.
    func beginRedactionReview(_ analysis: VisionAnalysis) {
        isFindingRedactions = false
        isRedactionReviewActive = true
        recognizedLines = analysis.lines
        recognizedWords = analysis.words
        highlightBoxes = analysis.highlightBoxes(in: document.baseImage.size)
        redactionCandidates = analysis.candidates
        redactionAssistError = nil
        if !redactionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stageQueryMatches()
        }
    }

    func failRedactionReview(_ message: String) {
        isFindingRedactions = false
        isRedactionReviewActive = true
        redactionAssistError = message
    }

    func dismissRedactionReview() {
        redactionCandidates = []
        isRedactionReviewActive = false
        isFindingRedactions = false
        redactionAssistError = nil
    }

    func reopenRedactionReview() {
        isRedactionReviewActive = true
    }

    func acceptRedaction(_ id: UUID) {
        guard let index = redactionCandidates.firstIndex(where: { $0.id == id }) else { return }
        let candidate = redactionCandidates.remove(at: index)
        appendRedaction(for: candidate)
    }

    func skipRedaction(_ id: UUID) {
        redactionCandidates.removeAll { $0.id == id }
    }

    /// One undo step for the whole batch.
    func acceptAllRedactions() {
        let remaining = redactionCandidates
        redactionCandidates = []
        guard !remaining.isEmpty else { return }
        let size = document.baseImage.size
        let style = styleMemory.lastRedactionStyle
        appendRedactionCommands(remaining.map { RedactionSpec(rect: $0.rect(in: size), style: style) })
    }

    /// Rebuilds `.custom` candidates from the find field without applying them.
    func stageQueryMatches() {
        let query = redactionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        redactionCandidates.removeAll { $0.kind == .custom }
        guard query.count >= 2 else { return }

        let custom = recognizedLines.flatMap { line -> [RedactionCandidate] in
            SecretScanner.matches(query: query, in: line.text).map { match in
                RedactionCandidate(
                    kind: .custom,
                    text: match.text,
                    boundingBox: VisionNormalizedBox.proportionalTopLeft(
                        visionLineBox: line.boundingBox,
                        text: line.text,
                        utf16Range: match.nsRange
                    )
                )
            }
        }
        redactionCandidates.append(contentsOf: custom)
    }

    private func appendRedaction(for candidate: RedactionCandidate) {
        appendRedactionCommands([
            RedactionSpec(
                rect: candidate.rect(in: document.baseImage.size),
                style: styleMemory.lastRedactionStyle
            )
        ])
    }

    func appendRedactionCommands(_ specs: [RedactionSpec]) {
        guard let first = specs.first else { return }
        if specs.count == 1 {
            document.add(.redaction(first))
            document.selection = [first.id]
            return
        }
        document.perform { commands in
            for spec in specs {
                commands.append(.redaction(spec))
            }
        }
    }
}
