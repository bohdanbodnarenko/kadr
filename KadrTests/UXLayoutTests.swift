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

    @Test("1.4× and 2× expanded strings stay inside the compact HUD width budget")
    func expandedLabelsFitCompactHUD() {
        let titles = AllInOneMode.allCases.map(\.title)
        for title in titles {
            let expanded = Pseudolocalization.expand(title, factor: 1.4)
            let doubled = Pseudolocalization.expand(title, factor: 2.0)
            #expect(expanded.count > title.count)
            #expect(doubled.count > expanded.count)
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
