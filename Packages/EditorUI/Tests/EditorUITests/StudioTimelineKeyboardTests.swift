import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// The timeline from the keyboard (docs/17 T-STU-11).
@MainActor
@Suite("Studio timeline keyboard")
struct StudioTimelineKeyboardTests {
    @Test("The clock shows frames", arguments: [
        (0.0, 30, "00:00:00"),
        (1.5, 30, "00:01:15"),
        (61.0 + 29.0 / 30.0, 30, "01:01:29"),
        (2.0 / 60.0, 60, "00:00:02"),
        (3661.0, 25, "1:01:01:00"),
        (-4.0, 30, "00:00:00")
    ])
    func frameClock(seconds: Double, frameRate: Int, expected: String) {
        #expect(StudioClock.frames(seconds, frameRate: frameRate) == expected)
    }

    @Test("Up and down step between edit points, and stop at the ends")
    func editPoints() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 3)
        studio.playhead = 1
        studio.splitAtPlayhead()
        studio.playhead = 2
        studio.splitAtPlayhead()

        studio.playhead = 0.5
        studio.seekToEditPoint(forward: true)
        #expect(abs(studio.playhead - 1) < 0.01)
        studio.seekToEditPoint(forward: true)
        #expect(abs(studio.playhead - 2) < 0.01)
        studio.seekToEditPoint(forward: true)
        #expect(abs(studio.playhead - studio.edit.duration) < 0.01)
        studio.seekToEditPoint(forward: false)
        #expect(abs(studio.playhead - 2) < 0.01)
        studio.playhead = 0.2
        studio.seekToEditPoint(forward: false)
        #expect(studio.playhead == 0)
    }

    @Test("J steps back, K stops, L plays")
    func shuttle() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 3)
        studio.playhead = 2.5
        studio.shuttle(.reverse)
        #expect(abs(studio.playhead - 1.5) < 0.01)
        studio.shuttle(.reverse)
        #expect(studio.playhead < 0.01, "a second J goes twice as far")
        studio.shuttle(.forward)
        #expect(studio.shuttleSpeed == 1)
        studio.shuttle(.stop)
        #expect(studio.shuttleSpeed == 0)
        #expect(!studio.isPlaying)
    }
}
