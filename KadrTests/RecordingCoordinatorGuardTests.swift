import CaptureCore
import Foundation
import RecordingCore
import SettingsKit
import Testing
@testable import Kadr

/// The coordinator's start and reset guards (docs/17 T-REC-2/3/4/8/9/11).
///
/// None of these need ScreenCaptureKit: every guard under test returns before the engine
/// is asked for anything, which is the point of a guard.
@MainActor
@Suite("Recording coordinator guards")
struct RecordingCoordinatorGuardTests {
    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            captureEngine: CaptureEngine(),
            permissions: PermissionCoordinator(),
            settings: AppSettings(store: throwawayDefaults())
        )
    }

    /// T-REC-3/4: a second start used to orphan the running take, and a start during the
    /// save found the old studio session attached.
    @Test(
        "A start is refused while any take exists",
        arguments: [RecordingState.starting, .recording, .paused, .finishing]
    )
    func startIsRefusedWhileBusy(state: RecordingState) {
        let coordinator = makeCoordinator()
        coordinator.state = state
        coordinator.startAfterCountdown(target: .display(1))
        #expect(coordinator.state == state)
        #expect(coordinator.pendingTarget == nil)
        #expect(coordinator.isBusy)
    }

    @Test("A take being saved is busy but no longer recording")
    func savingIsBusyNotRecording() {
        let coordinator = makeCoordinator()
        coordinator.state = .finishing
        #expect(coordinator.isBusy)
        #expect(!coordinator.isRecording)
    }

    /// T-REC-2 and T-REC-9: a take that never started hands back its claim and its flags.
    @Test("An abandoned start returns to idle and forgets its one-run flags")
    func abandonResetsEverything() {
        let coordinator = makeCoordinator()
        coordinator.state = .starting
        coordinator.wantsGIFExport = true
        coordinator.startedByAutomation = true
        coordinator.isTransitioning = true
        coordinator.pendingTarget = .display(1)

        coordinator.abandonUnstartedRecording(reason: "no permission")

        #expect(coordinator.state == .idle)
        #expect(!coordinator.wantsGIFExport)
        #expect(!coordinator.startedByAutomation)
        #expect(!coordinator.isTransitioning)
        #expect(coordinator.pendingTarget == nil)
    }

    /// T-REC-8: the 10 Hz tick must never outlive the take (rule 2).
    @Test("Clearing a take stops the tick and forgets the clock")
    func clearingStopsTheTick() {
        let coordinator = makeCoordinator()
        coordinator.state = .recording
        coordinator.startedAt = Date()
        coordinator.startTicking()
        #expect(coordinator.tickTask != nil)

        coordinator.clearTakeState()

        #expect(coordinator.tickTask == nil)
        #expect(coordinator.startedAt == nil)
        #expect(coordinator.elapsed == 0)
    }

    @Test(
        "VoiceOver hears the take start, pause, resume and end",
        arguments: [
            (RecordingState.starting, RecordingState.recording, "Recording started"),
            (.recording, .paused, "Recording paused"),
            (.paused, .recording, "Recording resumed"),
            (.recording, .finishing, "Saving recording"),
            (.finishing, .idle, "Recording saved"),
            (.paused, .idle, "Recording discarded")
        ]
    )
    func announcements(from old: RecordingState, to new: RecordingState, message: String) {
        #expect(RecordingAnnouncement.message(from: old, to: new) == message)
    }

    @Test("A countdown starting or being called off says nothing")
    func quietTransitions() {
        #expect(RecordingAnnouncement.message(from: .idle, to: .starting) == nil)
        #expect(RecordingAnnouncement.message(from: .starting, to: .idle) == nil)
    }

    /// T-REC-9: a camera switched on without choosing a device used to record nothing.
    @Test("A wanted camera with no device falls back to the default, or says there is none")
    func cameraFallsBackToDefault() {
        let none = RecordingInputResolver.resolve(
            options: RecordingOptions(capturesSystemAudio: false, capturesMicrophone: false),
            cameraDeviceID: "",
            wantsCamera: true,
            defaultCamera: { nil }
        )
        #expect(none.cameraDeviceID.isEmpty)
        #expect(none.notice == "No camera found — recording without it.")

        let unwanted = RecordingInputResolver.resolve(
            options: RecordingOptions(capturesSystemAudio: false, capturesMicrophone: false),
            cameraDeviceID: "",
            wantsCamera: false,
            defaultCamera: { "should-not-be-used" }
        )
        #expect(unwanted.cameraDeviceID.isEmpty)
        #expect(unwanted.notice == nil)
    }
}
