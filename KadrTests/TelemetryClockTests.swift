import AppKit
import Foundation
import RecordingCore
import StudioCore
import Testing
@testable import Kadr

/// The clock the sidecar stamps its events with (docs/10 R0.1).
///
/// Its own suite because the defect it guards against was invisible from either side of
/// the seam. The recorder was correct, the policy was correct, the engine computed the
/// right number — and nothing connected the third to the first, so every event in every
/// sidecar was stamped zero and the sample-rate gate compared zero against zero and refused
/// every pointer sample after the first. Two suites passed while the flagship was inert.
///
/// So these tests drive the clock rather than assuming it, and the first one is the one
/// that would have caught it.
@MainActor
@Suite("Telemetry clock")
struct TelemetryClockTests {
    private func recorder() -> PointerTelemetryRecorder {
        let recorder = PointerTelemetryRecorder()
        // An identity converter: the conversion is `WindowSpace`'s business and is tested
        // there. What matters here is that the *time* moves.
        recorder.start(pointConverter: { $0 })
        return recorder
    }

    // MARK: - The defect

    /// The regression test for the headline bug. With a clock that never moves,
    /// `TelemetryPolicy.shouldRecord` asks whether 1/60th of a second has passed since the
    /// last sample, gets zero, and says no — forever.
    @Test("A moving clock records more than one pointer sample")
    func clockAdvancesProduceSamples() {
        let recorder = recorder()
        for step in 0 ..< 10 {
            recorder.advance(to: Double(step) * 0.1)
            recorder.recordPointerForTesting(at: CGPoint(x: Double(step) * 40, y: 100))
        }
        let telemetry = recorder.stop()
        #expect(telemetry.pointer.count >= 8, "only \(telemetry.pointer.count) samples were kept")
    }

    /// The exact shape the review asked for: advance, record, advance, record — two samples
    /// with distinct times.
    @Test("Two samples at two times carry two timestamps")
    func samplesCarryDistinctTimes() {
        let recorder = recorder()
        recorder.advance(to: 1)
        recorder.recordPointerForTesting(at: CGPoint(x: 10, y: 10))
        recorder.advance(to: 2)
        recorder.recordPointerForTesting(at: CGPoint(x: 400, y: 400))

        let pointer = recorder.stop().pointer
        #expect(pointer.count == 2)
        #expect(pointer.first?.time == 1)
        #expect(pointer.last?.time == 2)
    }

    /// A frozen clock is the failure, stated as a test so nobody has to infer it from the
    /// one above: with no advance, the gate keeps exactly the first sample.
    @Test("A clock that never moves keeps only the first sample")
    func frozenClockKeepsOnlyOne() {
        let recorder = recorder()
        for step in 0 ..< 10 {
            recorder.recordPointerForTesting(at: CGPoint(x: Double(step) * 40, y: 100))
        }
        #expect(recorder.stop().pointer.count == 1)
    }

    // MARK: - Everything stamped by it

    @Test("Clicks are stamped with the clock, not with zero")
    func clicksAreStamped() {
        let recorder = recorder()
        recorder.advance(to: 4.25)
        recorder.recordClickForTesting(at: CGPoint(x: 100, y: 100))

        let clicks = recorder.stop().clicks
        #expect(clicks.count == 1)
        #expect(clicks.first?.time == 4.25)
    }

    /// What the sidecar's length is derived from. A zero duration makes the reconstructed
    /// cursor a stationary dot and clusters every click into one zoom cue at 0:00.
    @Test("The telemetry spans the recording rather than an instant")
    func telemetryHasDuration() {
        let recorder = recorder()
        for step in 0 ..< 50 {
            recorder.advance(to: Double(step) * 0.1)
            recorder.recordPointerForTesting(at: CGPoint(x: Double(step) * 20, y: 100))
        }
        let telemetry = recorder.stop()
        let span = (telemetry.pointer.last?.time ?? 0) - (telemetry.pointer.first?.time ?? 0)
        #expect(span > 4, "the sidecar spans \(span)s of a 4.9s recording")
    }

    // MARK: - Where the clock comes from

    /// The wiring, asserted structurally. The engine already computed this number and
    /// published it only to the overlay provider — which the coordinator installs only when
    /// the user wants a halo or a caption, i.e. never in the studio case. A clock delivered
    /// as a side effect of drawing overlays is a clock the quiet path does not get.
    @Test("The clock has a channel of its own, not one borrowed from overlays")
    func clockIsNotTiedToOverlays() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kadr/Recording/RecordingCoordinator.swift"),
            encoding: .utf8
        )
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.contains("observeClock()"), "nothing installs the clock observer")
        // Installed alongside the session, not alongside the overlays: the studio case is
        // precisely the one with no overlays.
        let installedWithSession = code.range(of: "studio.start(").map { range in
            code[range.upperBound...].prefix(400).contains("observeClock()")
        } ?? false
        #expect(installedWithSession, "the clock is not installed with the studio session")
    }
}
