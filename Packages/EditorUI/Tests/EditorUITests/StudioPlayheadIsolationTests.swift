import CoreGraphics
import Foundation
import Observation
import os
import StudioSession
import Testing
@testable import EditorUI

/// Playback must not invalidate the studio (docs/11 S2).
///
/// The playhead moves thirty times a second. Every SwiftUI body that read it re-rendered on
/// each of those writes, and on the document model that was the timeline, the transport,
/// the inspector and the transcript at once. These tests pin the contract that fixed it:
/// a playhead or hover write reaches only the playhead clock, and the model's own observed
/// state changes only when a derived answer — the clip under the playhead — does.
@MainActor
@Suite("Studio playhead isolation")
struct StudioPlayheadIsolationTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-playhead-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL, telemetry: InputTelemetry = InputTelemetry()) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        let document = SessionDocument(session: session)
        try document.write(telemetry)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 10,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    /// Whether `observe` saw a change during `act`.
    private func changes(observing observe: () -> Void, during act: () -> Void) -> Bool {
        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking(observe) {
            fired.withLock { $0 = true }
        }
        act()
        return fired.withLock { $0 }
    }

    /// Everything a parent view reads from the model, minus the derived playhead state.
    private func readParentState(of studio: StudioDocumentModel) {
        _ = studio.edit
        _ = studio.selectedZoom
        _ = studio.selectedClip
        _ = studio.exportProgress
        _ = studio.transcript
        _ = studio.notice
        _ = studio.failure
        _ = studio.isCropping
        _ = studio.chapters
    }

    @Test("Moving the playhead inside a clip changes nothing a parent view reads")
    func playheadWritesStayOnTheClock() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 1

        #expect(!changes(observing: { readParentState(of: studio) }, during: { studio.playhead = 2 }))
        #expect(!changes(observing: { _ = studio.currentClipIndex }, during: { studio.playhead = 3 }))
        #expect(!changes(observing: { _ = studio.playheadIsInsideEdit }, during: { studio.playhead = 4 }))
        #expect(changes(observing: { _ = studio.playheadClock.time }, during: { studio.playhead = 5 }))
        #expect(studio.playhead == 5)
    }

    @Test("Crossing a cut is the one playhead write the model publishes")
    func crossingACutChangesTheClipIndex() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 5
        studio.splitAtPlayhead()
        studio.playhead = 2
        #expect(studio.currentClipIndex == 0)

        #expect(changes(observing: { _ = studio.currentClipIndex }, during: { studio.playhead = 7 }))
        #expect(studio.currentClipIndex == 1)
        #expect(!changes(observing: { readParentState(of: studio) }, during: { studio.playhead = 1 }))
    }

    @Test("Reaching an end flips the trim flag, and only then")
    func trimFlagFlipsAtTheEdges() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(!studio.playheadIsInsideEdit)
        #expect(changes(observing: { _ = studio.playheadIsInsideEdit }, during: { studio.playhead = 3 }))
        #expect(studio.playheadIsInsideEdit)
        #expect(changes(observing: { _ = studio.playheadIsInsideEdit }, during: { studio.playhead = 10 }))
        #expect(!studio.playheadIsInsideEdit)
    }

    @Test("An edit that moves the cut under the playhead updates the clip index")
    func editsRefreshTheClipIndex() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 6
        #expect(studio.currentClipIndex == 0)
        studio.split(at: 4)
        #expect(studio.currentClipIndex == 1)
        studio.undo()
        #expect(studio.currentClipIndex == 0)
        studio.redo()
        #expect(studio.currentClipIndex == 1)
    }

    @Test("Hovering reaches the clock, not the model")
    func hoverStaysOnTheClock() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        #expect(!changes(observing: { readParentState(of: studio) }, during: { studio.hoverPreviewTime = 2 }))
        #expect(changes(observing: { _ = studio.playheadClock.hoverTime }, during: { studio.hoverPreviewTime = 3 }))
        #expect(!changes(observing: { _ = studio.playheadClock.hoverTime }, during: { studio.hoverPreviewTime = 3 }))
        #expect(!changes(observing: { _ = studio.playheadClock.time }, during: { studio.hoverPreviewTime = nil }))
        #expect(studio.hoverPreviewTime == nil)
    }

    @Test("Setting the playhead to where it is publishes nothing")
    func equalWritesAreSilent() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 4
        #expect(!changes(observing: { _ = studio.playheadClock.time }, during: { studio.playhead = 4 }))
        #expect(changes(observing: { _ = studio.playheadClock.time }, during: { studio.playhead = 10.5 }))
        #expect(studio.playhead == 10)
    }

    // MARK: - Lookups that run per tick

    struct ClipIndexCase: Sendable {
        var ends: [TimeInterval]
        var time: TimeInterval
        var expected: Int?
    }

    struct PointerCase: Sendable {
        var times: [TimeInterval]
        var time: TimeInterval
        var expected: Int?
    }

    struct DecimationCase: Sendable {
        var count: Int
        var limit: Int
        var expected: Int
    }

    nonisolated static let clipIndexCases: [ClipIndexCase] = [
        ClipIndexCase(ends: [], time: 1.0, expected: nil),
        ClipIndexCase(ends: [10], time: 0, expected: 0),
        ClipIndexCase(ends: [10], time: 10, expected: 0),
        ClipIndexCase(ends: [10], time: 99, expected: 0),
        ClipIndexCase(ends: [4, 7, 10], time: 0, expected: 0),
        ClipIndexCase(ends: [4, 7, 10], time: 3.999, expected: 0),
        ClipIndexCase(ends: [4, 7, 10], time: 4, expected: 1),
        ClipIndexCase(ends: [4, 7, 10], time: 6.5, expected: 1),
        ClipIndexCase(ends: [4, 7, 10], time: 7, expected: 2),
        ClipIndexCase(ends: [4, 7, 10], time: 10, expected: 2),
        ClipIndexCase(ends: [4, 7, 10], time: -1, expected: 0)
    ]

    @Test(
        "The clip under an instant is the first clip ending after it",
        arguments: Self.clipIndexCases
    )
    func clipIndexSearch(_ row: ClipIndexCase) {
        #expect(StudioDocumentModel.clipIndex(at: row.time, ends: row.ends) == row.expected)
    }

    nonisolated static let pointerCases: [PointerCase] = [
        PointerCase(times: [], time: 1.0, expected: nil),
        PointerCase(times: [1], time: 0.5, expected: nil),
        PointerCase(times: [1], time: 1, expected: 0),
        PointerCase(times: [0, 1, 2, 3], time: 2.5, expected: 2),
        PointerCase(times: [0, 1, 2, 3], time: 3, expected: 3),
        PointerCase(times: [0, 1, 2, 3], time: 99, expected: 3),
        PointerCase(times: [0, 1, 1, 2], time: 1, expected: 2)
    ]

    @Test(
        "The pointer sample at an instant is the last one at or before it",
        arguments: Self.pointerCases
    )
    func pointerSearch(_ row: PointerCase) {
        let samples = row.times.map { PointerSample(time: $0, position: CGPoint(x: $0, y: 0)) }
        #expect(StudioDocumentModel.lastIndex(in: samples, atOrBefore: row.time) == row.expected)
    }

    @Test("Aiming falls back to the first sample before the pointer was seen")
    func pointerFallsBackToTheFirstSample() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.pointer = [
            PointerSample(time: 2, position: CGPoint(x: 20, y: 0)),
            PointerSample(time: 4, position: CGPoint(x: 40, y: 0))
        ]
        let studio = try model(in: folder, telemetry: telemetry)
        #expect(studio.pointerPosition(at: 1) == CGPoint(x: 20, y: 0))
        #expect(studio.pointerPosition(at: 3) == CGPoint(x: 20, y: 0))
        #expect(studio.pointerPosition(at: 9) == CGPoint(x: 40, y: 0))
        #expect(studio.hasPointerAtPlayhead)
    }

    nonisolated static let decimationCases: [DecimationCase] = [
        DecimationCase(count: 0, limit: 800, expected: 0),
        DecimationCase(count: 800, limit: 800, expected: 800),
        DecimationCase(count: 801, limit: 800, expected: 801),
        DecimationCase(count: 1600, limit: 800, expected: 800),
        DecimationCase(count: 2500, limit: 800, expected: 834),
        DecimationCase(count: 10, limit: 0, expected: 10)
    ]

    @Test(
        "Click ticks are thinned evenly past the limit",
        arguments: Self.decimationCases
    )
    func clickDecimation(_ row: DecimationCase) {
        let times = (0 ..< row.count).map(TimeInterval.init)
        let thinned = StudioDocumentModel.decimated(times, limit: row.limit)
        #expect(thinned.count == row.expected)
        #expect(thinned.first == times.first)
    }

    @Test("Click ticks follow the clips")
    func clickTicksAreRebuiltAfterACut() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.clicks = [1, 6].map { ClickEvent(time: $0, position: .zero) }
        let studio = try model(in: folder, telemetry: telemetry)
        #expect(studio.clickTicks == [1, 6])
        studio.change { $0.clips = ClipTimeline(clips: [Clip(sourceStart: 5, sourceDuration: 5)]) }
        #expect(studio.clickTicks == [1])
    }

    // MARK: - Export progress

    nonisolated static let percentCases: [(value: Double, expected: Int)] = [
        (value: 0.0, expected: 0),
        (value: 0.004, expected: 0),
        (value: 0.0101, expected: 1),
        (value: 0.999, expected: 99),
        (value: 1.0, expected: 100),
        (value: 1.7, expected: 100),
        (value: -0.2, expected: 0),
        (value: Double.nan, expected: 0)
    ]

    @Test(
        "Progress is published by whole percent",
        arguments: Self.percentCases
    )
    func exportPercent(value: Double, expected: Int) {
        #expect(StudioDocumentModel.exportPercent(value) == expected)
    }

    @Test("A report within the same percent does not reach observers")
    func samePercentIsSilent() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.exportProgress = 0
        studio.publishedExportPercent = 0
        #expect(!changes(observing: { _ = studio.exportProgress }, during: { studio.publishExportProgress(0.005) }))
        #expect(changes(observing: { _ = studio.exportProgress }, during: { studio.publishExportProgress(0.012) }))
        #expect(!changes(observing: { _ = studio.exportProgress }, during: { studio.publishExportProgress(0.018) }))
        studio.exportProgress = nil
        studio.publishExportProgress(0.5)
        #expect(studio.exportProgress == nil, "a late report brought a finished export's bar back")
    }
}
