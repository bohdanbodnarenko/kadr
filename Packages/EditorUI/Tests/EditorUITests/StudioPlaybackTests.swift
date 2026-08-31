import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// Playing the edit, and moving a zoom (docs/08 §2 items 10 and 13).
///
/// Both were gaps rather than defects, which is why no test caught them: the preview could
/// only scrub, so a zoom or a cut could not be judged without a full export, and a cue's
/// start could not be changed at all — `addZoom` dropped it at the playhead and the
/// inspector offered everything about it except *when*.
@MainActor
@Suite("Studio playback")
struct StudioPlaybackTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-playback-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL, duration: TimeInterval = 10) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: duration,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    // MARK: - Transport

    @Test("Playing advances the playhead and pausing stops it")
    func playbackAdvancesAndStops() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.play()
        #expect(studio.isPlaying)
        try await Task.sleep(for: .milliseconds(250))
        let reached = studio.playhead
        #expect(reached > 0, "the playhead did not move")

        studio.pausePlayback()
        #expect(!studio.isPlaying)
        try await Task.sleep(for: .milliseconds(150))
        #expect(studio.playhead == reached, "the playhead kept moving after pause")
    }

    /// Timing comes from a clock rather than an accumulator, so a slow frame costs a dropped
    /// frame and not a drifting playhead.
    @Test("Playback keeps real time")
    func playbackKeepsRealTime() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.play()
        try await Task.sleep(for: .milliseconds(400))
        let elapsed = studio.playhead
        studio.pausePlayback()

        // Generous either way: this asserts "it tracks the clock", not the scheduler's
        // punctuality on a machine running fifteen test suites at once.
        #expect(elapsed > 0.15, "playback ran far behind the clock (\(elapsed)s in 0.4s)")
        #expect(elapsed < 0.9, "playback ran ahead of the clock (\(elapsed)s in 0.4s)")
    }

    @Test("Playing from the end starts again from the beginning")
    func playingFromTheEndRewinds() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = studio.edit.duration

        studio.play()
        defer { studio.pausePlayback() }
        #expect(studio.playhead < 1, "play did nothing visible at the end of the recording")
    }

    @Test("Playback stops itself at the end")
    func playbackStopsAtTheEnd() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder, duration: 0.2)
        studio.play()

        for _ in 0 ..< 40 where studio.isPlaying {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!studio.isPlaying, "playback ran past the end of the recording")
        #expect(studio.playhead == studio.edit.duration)
    }

    /// Stepping while playing is two things moving one value, and the user loses.
    @Test("Stepping pauses playback")
    func steppingPauses() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.play()

        studio.step(frames: 1)
        #expect(!studio.isPlaying)
    }

    @Test("Stepping moves by whole frames of the recording")
    func steppingMovesOneFrame() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 5

        studio.step(frames: 1)
        #expect(abs(studio.playhead - (5 + 1.0 / 60)) < 0.0001)
        studio.step(frames: -1)
        #expect(abs(studio.playhead - 5) < 0.0001)
    }

    /// The playhead's own clamp still applies, so stepping back from zero stays at zero
    /// rather than going negative and asking the generator for a frame before the recording.
    @Test("Stepping cannot leave the recording")
    func steppingStaysInside() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.step(frames: -10)
        #expect(studio.playhead == 0)
        studio.playhead = studio.edit.duration
        studio.step(frames: 10)
        #expect(studio.playhead == studio.edit.duration)
    }

    // MARK: - Moving a zoom

    @Test("A zoom can be moved to a new start")
    func zoomCanBeMoved() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 1
        studio.addZoom()
        let id = try #require(studio.selectedZoom)

        studio.moveZoom(id, to: 4)
        let cue = try #require(studio.edit.zooms.first { $0.id == id })
        #expect(abs(cue.start - 4) < 0.0001)
    }

    /// A cue that runs off the end never finishes playing, and the recording stops
    /// mid-zoom — so the whole footprint, hold *and* both moves, has to fit.
    @Test("A zoom cannot be moved past the end of the recording")
    func zoomIsClampedToTheRecording() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 1
        studio.addZoom()
        let id = try #require(studio.selectedZoom)

        studio.moveZoom(id, to: 999)
        let cue = try #require(studio.edit.zooms.first { $0.id == id })
        #expect(cue.end <= studio.edit.duration + 0.0001, "the cue ends after the recording does")

        studio.moveZoom(id, to: -5)
        let back = try #require(studio.edit.zooms.first { $0.id == id })
        #expect(back.start == 0)
    }

    /// Dragging a cue along the timeline is one gesture, so it is one undo step.
    @Test("Dragging a zoom is a single undo step")
    func draggingAZoomIsOneUndoStep() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 1
        studio.addZoom()
        let id = try #require(studio.selectedZoom)
        let before = try #require(studio.edit.zooms.first { $0.id == id }).start

        for step in 1 ... 30 {
            studio.moveZoom(id, to: 1 + Double(step) * 0.1)
        }
        studio.undo()

        let cue = try #require(studio.edit.zooms.first { $0.id == id })
        #expect(abs(cue.start - before) < 0.0001, "undo landed in the middle of the drag")
    }

    // MARK: - The ruler

    /// The labels have to stay apart at any length, or the ruler is a smear.
    @Test(
        "Tick intervals keep the labels readable",
        arguments: [10.0, 60.0, 600.0, 3600.0]
    )
    func tickIntervalsScale(duration: TimeInterval) {
        let width: CGFloat = 800
        let step = StudioTimelineView.tickInterval(forDuration: duration, width: width)
        #expect(step > 0)

        let spacing = CGFloat(step / duration) * width
        #expect(spacing >= 56, "labels \(spacing)pt apart on a \(duration)s recording")
        // And not so far apart that there are no labels at all.
        #expect(step <= duration, "a \(duration)s recording got a \(step)s tick")
    }

    @Test("Tick labels read as minutes and seconds")
    func tickLabelsAreClock() {
        #expect(StudioTimelineView.tickLabel(0) == "0:00")
        #expect(StudioTimelineView.tickLabel(65) == "1:05")
        #expect(StudioTimelineView.tickLabel(600) == "10:00")
    }
}
