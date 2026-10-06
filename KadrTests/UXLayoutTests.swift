import CoreGraphics
import Foundation
import Testing
@testable import Kadr

@MainActor
@Suite("Layout contract (docs/14 UX-05)")
struct UXLayoutTests {
    @Test("Declared window minimums match the contract")
    func windowMinimums() {
        #expect(SettingsWindowGeometry.minimumSize.width == UXLayoutContract.settingsMinimum.width)
        #expect(SettingsWindowGeometry.minimumSize.height == UXLayoutContract.settingsMinimum.height)
        #expect(HistoryWindowGeometry.minimumSize.width == UXLayoutContract.historyMinimum.width)
        #expect(HistoryWindowGeometry.minimumSize.height == UXLayoutContract.historyMinimum.height)
        #expect(UXLayoutContract.editorMinimum.width == 760)
        #expect(UXLayoutContract.studioMinimum.width == 820)
        #expect(UXLayoutContract.overlayCardMinimumWidth == 140)
        #expect(UXLayoutContract.hitTargetMinimum == 20)
    }

    @Test("Primary windows fit every supported visibleFrame")
    func windowsFitSupportedDisplays() {
        for visible in UXLayoutContract.supportedVisibleFrames {
            #expect(UXLayoutContract.fits(UXLayoutContract.settingsMinimum, in: visible))
            #expect(UXLayoutContract.fits(UXLayoutContract.historyMinimum, in: visible))
            #expect(UXLayoutContract.fits(UXLayoutContract.editorMinimum, in: visible))
            #expect(UXLayoutContract.fits(UXLayoutContract.studioMinimum, in: visible))
            #expect(UXLayoutContract.fits(UXLayoutContract.onboardingMinimum, in: visible))
            #expect(UXLayoutContract.compactHUDWidth <= visible.width)
        }
    }

    @Test("Every mode title, doubled by the pseudolanguage, fits the compact island")
    func doubledLabelsFitCompactHUD() {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for title in AllInOneMode.allCases.map(\.title) {
            let doubled = Pseudolocalization.doubled(title)
            let width = (doubled as NSString).size(withAttributes: [.font: font]).width
            #expect(width < UXLayoutContract.compactHUDWidth, "“\(doubled)” is \(width) pt wide")
        }
        #expect(UXLayoutContract.compactHUDWidth <= 1024)
    }
}

@MainActor
@Suite("Capture access gate (docs/14 UX-17)")
struct CaptureAccessGateTests {
    @Test("Only an allowed grant skips the popover")
    func needsPrompt() {
        #expect(!CaptureAccessGate.needsPrompt(status: .allowed))
        #expect(CaptureAccessGate.needsPrompt(status: .notEnabled))
        #expect(CaptureAccessGate.needsPrompt(status: .denied))
        #expect(CaptureAccessGate.needsPrompt(status: .restricted))
    }

    @Test("Camera and microphone prompts have distinct copy")
    func promptCopy() {
        #expect(CaptureAccessKind.camera.title != CaptureAccessKind.microphone.title)
        #expect(CaptureAccessKind.camera.prompt.contains("camera"))
        #expect(CaptureAccessKind.microphone.prompt.contains("microphone"))
    }
}
