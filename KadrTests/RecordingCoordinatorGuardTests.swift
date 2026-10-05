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

    /// docs/18 REC-1: a microphone the take must go without is flagged for the whole take,
    /// and its notice wins over a camera's.
    @Test("A missing microphone is flagged and named first")
    func missingMicrophoneIsFlagged() {
        let resolved = RecordingInputResolver.resolve(
            options: RecordingOptions(
                capturesSystemAudio: false,
                capturesMicrophone: true,
                microphoneDeviceID: "unplugged-\(UUID().uuidString)"
            ),
            cameraDeviceID: "",
            wantsCamera: true,
            defaultCamera: { nil }
        )
        #expect(resolved.droppedMicrophone)
        #expect(!resolved.options.capturesMicrophone)
        #expect(resolved.notice == "Microphone unavailable — recording without it.")
    }

    /// docs/18 REC-5: wake explains a pause Kadr took for sleep, and only that one.
    @Test("Wake explains a pause taken for sleep", arguments: [
        (true, RecordingState.paused, true),
        (false, .paused, false),
        (true, .idle, false)
    ])
    func wakeExplainsSleepPause(pausedForSleep: Bool, state: RecordingState, explains: Bool) {
        let coordinator = makeCoordinator()
        coordinator.state = state
        coordinator.pausedForSleep = pausedForSleep

        coordinator.systemDidWake()

        #expect((coordinator.liveNotice == RecordingCoordinator.sleepNotice) == explains)
        #expect(!coordinator.pausedForSleep)
    }

    @Test("Sleep leaves anything but a running take alone", arguments: [
        RecordingState.idle, .starting, .paused, .finishing
    ])
    func sleepIgnoresOtherStates(state: RecordingState) {
        let coordinator = makeCoordinator()
        coordinator.state = state
        coordinator.systemWillSleep()
        #expect(!coordinator.pausedForSleep)
        #expect(coordinator.state == state)
    }

    /// docs/18 REC-7: a stream that dies before the start claims `.recording` is held,
    /// not dropped, so the take is saved once it starts instead of looking live forever.
    @Test("A stream death while starting is held for the start to replay")
    func streamDeathDuringStartIsHeld() {
        let coordinator = makeCoordinator()
        coordinator.state = .starting
        coordinator.handleEngineEvent(.streamStopped("The display went away."))
        #expect(coordinator.pendingInterruption == "The display went away.")
        #expect(coordinator.state == .starting)
    }

    /// docs/18 REC-7: cancel's trailing cleanup used to knock a take started in the
    /// meantime back to idle.
    @Test("Cancel's cleanup leaves a newer take alone")
    func cancelSparesNewerTake() async {
        let coordinator = makeCoordinator()
        coordinator.state = .recording
        coordinator.cancel()

        // A new take claims the coordinator before the engine finishes winding down.
        coordinator.state = .starting
        coordinator.startGeneration &+= 1
        coordinator.wantsGIFExport = true
        for _ in 0 ..< 200 {
            await Task.yield()
        }

        #expect(coordinator.state == .starting)
        #expect(coordinator.wantsGIFExport)
    }

    /// docs/18 REC-10: only the take's own inputs count as lost.
    @Test("A disconnection loses only the take's own input", arguments: [
        ("mic-a", true, false, String?.some("mic-a"), String?.none, 1, RecordingCoordinator.LostInput?.some(.microphone)),
        ("mic-b", true, false, "mic-a", nil, 1, nil),
        ("mic-a", true, false, "", nil, 1, nil),
        ("mic-a", true, false, "", nil, 0, .microphone),
        ("mic-a", true, false, nil, nil, 0, nil),
        ("cam-a", false, true, nil, "cam-a", 1, .camera),
        ("cam-b", false, true, nil, "cam-a", 1, nil)
    ])
    func lostInput(
        id: String,
        isAudio: Bool,
        isVideo: Bool,
        microphone: String?,
        camera: String?,
        remaining: Int,
        expected: RecordingCoordinator.LostInput?
    ) {
        #expect(RecordingCoordinator.lostInput(
            disconnectedID: id,
            isAudio: isAudio,
            isVideo: isVideo,
            microphoneID: microphone,
            cameraID: camera,
            remainingAudioDevices: remaining
        ) == expected)
    }

    /// docs/18 REC-10: after a denial macOS never prompts again, so Allow is not offered.
    @Test("Allow is offered only while macOS can still ask", arguments: [
        (AppPermissionStatus.notEnabled, true),
        (.denied, false),
        (.restricted, false)
    ])
    func allowOffered(status: AppPermissionStatus, canAsk: Bool) {
        #expect(CaptureAccessGate.canAsk(status: status) == canAsk)
    }
}
