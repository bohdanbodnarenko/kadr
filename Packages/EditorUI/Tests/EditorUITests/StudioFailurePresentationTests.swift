import Foundation
import Testing
@testable import EditorUI

@Suite("Studio failure presentation")
struct StudioFailurePresentationTests {
    @Test("Export failures offer retry and another location")
    func exportFailureActions() {
        let failure = StudioFailurePresentation.exportFailed("Disk full.")
        #expect(failure.primaryAction == .retry)
        #expect(failure.secondaryAction == .chooseExportLocation)
        #expect(failure.style == .inlineBanner)
    }

    @Test("Tidy refusal is a sheet with the legacy message")
    func tidyRefusalPresentation() {
        let failure = StudioFailurePresentation.tidyRefused()
        #expect(failure.style == .sheet)
        #expect(failure.message == StudioDocumentModel.tidyRefusal)
    }
}
