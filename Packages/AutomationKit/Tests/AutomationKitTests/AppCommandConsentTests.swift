import Foundation
import Shared
import Testing
@testable import AutomationKit

/// docs/18 OUT-13: the consent prompt names the file or region a request reaches.
@Suite("Consent details")
struct AppCommandConsentTests {
    @Test("Files are named by their last path component")
    func files() {
        let pin = AppCommand.pin(FileTarget(path: "~/Secrets/passport.png"))
        #expect(pin.consentDetails == ["Opens the file “passport.png”"])

        var options = CaptureOptions()
        options.path = "/Users/me/Documents/contract.pdf"
        #expect(AppCommand.captureText(options).consentDetails == ["Reads the file “contract.pdf”"])
    }

    @Test("A region and the microphone are called out")
    func regionAndMicrophone() {
        var capture = CaptureOptions()
        capture.region = ScreenRect(origin: ScreenPoint(x: 0, y: 0), width: 400, height: 300)
        #expect(AppCommand.captureArea(capture).consentDetails.first?.contains("400 × 300") == true)

        var record = RecordOptions()
        record.recordsMicrophone = true
        #expect(AppCommand.recordScreen(record).consentDetails == ["Records the microphone"])
    }

    @Test("A plain verb has nothing to add")
    func plain() {
        #expect(AppCommand.captureArea(.none).consentDetails.isEmpty)
        #expect(AppCommand.openHistory.consentDetails.isEmpty)
    }
}
