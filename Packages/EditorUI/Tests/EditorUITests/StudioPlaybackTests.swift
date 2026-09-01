import Foundation
import StudioSession
import Testing
@testable import EditorUI

@Suite("Studio clock")
struct StudioClockTests {
    @Test("The transport clock shows tenths of a second")
    func tenthsOfASecond() {
        #expect(StudioClock.precise(4.2) == "0:04.2")
        #expect(StudioClock.precise(65) == "1:05.0")
        #expect(StudioClock.precise(3723.4) == "1:02:03.4")
    }
}

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

    private func model(
        in folder: URL,
        duration: TimeInterval = 10,
        topInset: CGFloat = 0
    ) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: duration,
            hasBakedCursor: true,
            topInset: topInset
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    // MARK: - The notch strip (docs/08 §2 item 12)

    /// A full-screen recording on a notched MacBook has a bite out of the top, and no
    /// amount of framing hides it.
    @Test("Trimming the notch crops exactly the strip the display reported")
    func trimmingTheNotchCropsTheStrip() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // 74 pixels of a 1080-pixel-tall recording: a 37-point strip at 2×.
        let studio = try model(in: folder, topInset: 74)
        #expect(studio.canTrimNotch)

        studio.trimNotchStrip()
        let crop = try #require(studio.edit.cropRect)
        #expect(abs(crop.origin.y - 74.0 / 1080) < 0.0001)
        #expect(abs(crop.height - (1 - 74.0 / 1080)) < 0.0001)
        #expect(crop.origin.x == 0)
        #expect(crop.width == 1)
    }

    /// Offered only where there is one. A display without a notch, or a session recorded
    /// before the inset was captured, reports zero — and trimming a strip of unknown height
    /// would cut into the picture.
    @Test("A recording with no notch is not offered the trim")
    func noNotchNoTrim() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(!studio.canTrimNotch)

        studio.trimNotchStrip()
        #expect(studio.edit.cropRect == nil, "a recording with no notch was cropped anyway")
    }

    /// Removing the notch is something you do once: a second press would take another strip
    /// off whatever the first one left.
    @Test("The trim is not offered again once the recording is cropped")
    func trimIsOfferedOnce() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder, topInset: 74)

        studio.trimNotchStrip()
        #expect(!studio.canTrimNotch)
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

    @Test("Seeking jumps to the ends")
    func seekToEnds() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 5
        studio.seekToStart()
        #expect(studio.playhead == 0)
        studio.seekToEnd()
        #expect(studio.playhead == studio.edit.duration)
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

    @Test("A five-second skip jumps by time, not frames")
    func skippingFiveSeconds() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 2

        studio.step(seconds: 5)
        #expect(abs(studio.playhead - 7) < 0.0001)
        studio.step(seconds: -5)
        #expect(abs(studio.playhead - 2) < 0.0001)
        studio.step(seconds: -10)
        #expect(studio.playhead == 0)
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

    /// Stretching the timeline has to buy finer ticks, not the same five labels further
    /// apart — the whole reason to zoom is to see where inside a second you are.
    @Test("Zooming in gives a finer ruler")
    func zoomingGivesFinerTicks() {
        let duration: TimeInterval = 600
        let fit = StudioTimelineView.tickInterval(forDuration: duration, width: 800)
        let zoomed = StudioTimelineView.tickInterval(forDuration: duration, width: 800 * 32)

        #expect(zoomed < fit, "a 32× timeline got the same \(fit)s ticks")
        #expect(zoomed > 0)
    }

    /// Below a second the label has to say which part of the second, or every tick in a
    /// zoomed ruler reads the same.
    @Test("Sub-second ticks show tenths")
    func subSecondTicksShowTenths() {
        #expect(StudioTimelineView.tickLabel(65.4, step: 0.5) == "1:05.4")
        #expect(StudioTimelineView.tickLabel(65.4, step: 1) == "1:05")
    }

    /// A short recording must not get absurd ticks at any width.
    @Test(
        "Tick intervals stay sane at every zoom",
        arguments: [(10.0, 800.0), (10.0, 48000.0), (3600.0, 800.0), (3600.0, 48000.0)]
    )
    func tickIntervalsStaySane(duration: TimeInterval, width: CGFloat) {
        let step = StudioTimelineView.tickInterval(forDuration: duration, width: width)
        #expect(step > 0)
        #expect(step <= duration, "a \(duration)s recording got a \(step)s tick")
        let spacing = CGFloat(step / duration) * width
        #expect(spacing >= 40, "labels \(spacing)pt apart would collide")
    }
}
