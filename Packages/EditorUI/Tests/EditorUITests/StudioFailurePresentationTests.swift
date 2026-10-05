import ControlKit
import Foundation
import Testing
@testable import EditorUI

@Suite("Studio failure presentation")
struct StudioFailurePresentationTests {
    @Test("Export failures offer retry and another location")
    func exportFailureActions() {
        let destination = URL(fileURLWithPath: "/Users/me/Movies/Demo.mp4")
        let failure = StudioFailurePresentation.exportFailed("Disk full.", to: destination)
        #expect(failure.primaryAction == .retry(.export(destination)))
        #expect(failure.secondaryAction == .chooseExportLocation)
        #expect(failure.style == .inlineBanner)
    }

    @Test("Tidy refusal is a sheet with the legacy message")
    func tidyRefusalPresentation() {
        let failure = StudioFailurePresentation.tidyRefused()
        #expect(failure.style == .sheet)
        #expect(failure.message == StudioDocumentModel.tidyRefusal)
    }

    // MARK: - docs/18 STU-2: every Retry names what it re-runs

    @Test("Each retryable failure carries its own operation", arguments: [
        (StudioFailurePresentation.copyEditedFailed("x"), StudioFailurePresentation.Action.retry(.copyEdited)),
        (.shareEditedFailed("x"), .retry(.shareEdited)),
        (.speechModelDownloadFailed("x"), .retry(.installSpeechModel)),
        (.transcriptionFailed("x"), .retry(.transcribe)),
        (.transcriptionFailed("x", retryable: false), .dismiss),
        (.transcriptionFailed("x", retrying: .transcribeOnly), .retry(.transcribeOnly)),
        (
            .audioExportFailed("x", to: URL(fileURLWithPath: "/tmp/a.m4a"), format: .m4a),
            .retry(.exportAudio(URL(fileURLWithPath: "/tmp/a.m4a"), .m4a))
        )
    ])
    func retryCarriesOperation(failure: StudioFailurePresentation, expected: StudioFailurePresentation.Action) {
        #expect(failure.primaryAction == expected)
    }

    @Test("Actionable failures are errors; explanations are warnings")
    func feedbackKind() {
        #expect(StudioFailurePresentation.copyEditedFailed("x").kind == .error)
        #expect(StudioFailurePresentation.onlyClipLeft().kind == .warning)
        #expect(StudioFailurePresentation.speechPermissionNeeded().kind == .error)
    }
}
