import CoreGraphics
import Foundation
import RecordingCore
import SelectionUI
import SettingsKit
import Shared
import SwiftUI
import Testing
@testable import Kadr

@MainActor
@Suite("Record setup island")
struct RecordSetupModelTests {
    @Test("Arming a screen does not start the recording")
    func armingDoesNotStart() {
        var started: [RecordingTarget] = []
        let model = RecordSetupModel(settings: settings()) { started.append($0) }
        model.armScreen(1)
        #expect(started.isEmpty)
        #expect(model.recordingTarget == .display(1))
        #expect(model.isArmed(.screen))
    }

    @Test("Record commits the armed target")
    func recordCommitsArmedTarget() {
        var started: [RecordingTarget] = []
        let model = RecordSetupModel(settings: settings()) { started.append($0) }
        model.armScreen(42)
        model.record()
        #expect(started == [.display(42)])
    }

    @Test("Picking a window arms it and returns to the island")
    func pickingAWindowArmsIt() {
        var hidden = 0
        var revealed = 0
        let model = RecordSetupModel(settings: settings()) { _ in }
        model.onHideForPick = { hidden += 1 }
        model.onRevealAfterPick = { revealed += 1 }
        model.onPickWindow = { completion in
            completion(
                WindowSelection(
                    window: PickableWindow(
                        id: 7,
                        title: "Notes",
                        applicationName: "Notes",
                        bundleIdentifier: "com.apple.Notes",
                        frame: CGRect(x: 0, y: 0, width: 400, height: 300)
                    ),
                    display: DisplayGeometry(
                        displayID: 1,
                        frame: DisplayRect(x: 0, y: 0, width: 1440, height: 900),
                        scale: .retina
                    ),
                    togglesShadow: false
                )
            )
        }
        model.requestWindowPick()
        #expect(hidden == 1)
        #expect(revealed == 1)
        #expect(model.isArmed(.window))
        #expect(model.recordingTarget == .window(7))
    }

    @Test("Cancelling a window pick leaves the previous target")
    func cancellingAWindowPickKeepsTheScreen() {
        let model = RecordSetupModel(settings: settings()) { _ in }
        model.armScreen(1)
        model.onPickWindow = { $0(nil) }
        model.requestWindowPick()
        #expect(model.recordingTarget == .display(1))
    }

    @Test("Granting camera restores the island instead of starting")
    func grantingCameraRestoresTheIsland() {
        var started: [RecordingTarget] = []
        var revealed = 0
        var preview: [Bool] = []
        let settings = settings()
        let model = RecordSetupModel(settings: settings) { started.append($0) }
        model.onRevealAfterPick = { revealed += 1 }
        model.onCameraPreview = { preview.append($0) }
        model.armScreen(1)
        model.accessResume = .toggle
        model.accessPrompt = .camera
        model.completeAccessGrant(.camera)
        #expect(settings.recordingShowsWebcam)
        #expect(preview == [true])
        #expect(revealed == 1)
        #expect(started.isEmpty)
        #expect(model.accessPrompt == nil)
    }

    @Test("Granting camera after Record still starts the take")
    func grantingCameraThenRecordStarts() {
        var started: [RecordingTarget] = []
        var revealed = 0
        let model = RecordSetupModel(settings: settings()) { started.append($0) }
        model.onRevealAfterPick = { revealed += 1 }
        model.armScreen(1)
        model.accessResume = .record
        model.accessPrompt = .camera
        model.completeAccessGrant(.camera)
        #expect(started == [.display(1)])
        #expect(revealed == 0)
    }

    @Test("A permission sheet dismissing the popover does not drop the in-flight grant")
    func inFlightPopoverDismissKeepsResume() {
        let model = RecordSetupModel(settings: settings()) { _ in }
        model.accessResume = .toggle
        model.accessPrompt = .camera
        model.accessRequestInFlight = true
        model.accessPromptItem.wrappedValue = nil
        #expect(model.accessResume == .toggle)
        #expect(model.accessPrompt == nil)
    }

    private func settings() -> AppSettings {
        AppSettings(store: throwawayDefaults())
    }
}
