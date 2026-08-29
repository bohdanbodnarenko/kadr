import Foundation
import RecordingCore
import Testing
@testable import Kadr

/// The state a recording is in, and what that permits (docs/10 R0.3).
///
/// Its own suite because the hazard is a gap in time rather than a wrong value. Starting a
/// capture is several hundred milliseconds of asking ScreenCaptureKit for permission,
/// content and a stream; for the whole of that window the app used to report itself idle,
/// so a second trigger started a second recording — and the second one's failure path ran
/// `studio.cancel()`, deleting the *first* recording's session, and put the desktop icons
/// back while the first was still filming.
@Suite("Recording state")
struct RecordingStateTests {
    /// The question every guard in the coordinator actually means. Asking `== .recording`
    /// is the question almost nobody means, and answering the wrong one is what let two
    /// recordings overlap.
    @Test(
        "A recording that is starting counts as one",
        arguments: [
            (RecordingState.idle, false),
            (.starting, true),
            (.recording, true),
            (.paused, true),
            (.finishing, true)
        ]
    )
    func activeStates(state: RecordingState, isActive: Bool) {
        #expect(state.isActive == isActive)
    }

    @Test("Only idle is inactive")
    func idleIsTheOnlyInactiveState() {
        #expect(!RecordingState.idle.isActive)
        for state in [RecordingState.starting, .recording, .paused, .finishing] {
            #expect(state.isActive, "\(state) should count as a live recording")
        }
    }

    /// The guard, asserted structurally: it has to be claimed before the first `await`, or
    /// the window it exists to close is still open.
    @Test("The state is claimed synchronously, before the first await")
    func stateIsClaimedBeforeAwaiting() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kadr/Recording/RecordingCoordinator.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func start(target: RecordingTarget)"))
        let body = source[start.upperBound...].prefix(900)

        let claim = try #require(body.range(of: "state = .starting"))
        let task = try #require(body.range(of: "Task {"))
        #expect(
            claim.lowerBound < task.lowerBound,
            "the state is claimed inside the Task, which leaves the re-entrancy window open"
        )
    }
}
