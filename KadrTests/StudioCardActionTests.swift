import Foundation
import HistoryKit
import SettingsKit
import Shared
import StudioSession
import Testing
@testable import Kadr

/// Reaching a studio session from the card that announced the recording (docs/09 U3).
///
/// The gap this closes was not a missing feature but an unreachable one: sessions were
/// being written for every recording and the only way to open one was to find it in
/// Application Support by hand.
@MainActor
@Suite("Studio card action")
struct StudioCardActionTests {
    // MARK: - The layout offers it

    /// Placeable and never placed is the same as absent. Studio and Trim were both in that
    /// state, which left a recording's card with no way to edit the recording.
    @Test("The standard layout offers the studio on a recording")
    func standardLayoutOffersStudio() {
        let actions = CardLayout.standard.actions(in: .column, for: .recording)
        #expect(actions.contains(.studio))
        #expect(actions.contains(.trim))
    }

    @Test("The standard layout does not offer the studio on a screenshot")
    func screenshotsDoNotOfferStudio() {
        #expect(!CardLayout.standard.actions(in: .column, for: .screenshot).contains(.studio))
    }

    @Test("The studio applies to recordings only")
    func studioAppliesToRecordingsOnly() {
        #expect(CardAction.studio.applies(to: .recording))
        #expect(!CardAction.studio.applies(to: .screenshot))
    }

    @Test("Neither card is asked to draw more buttons than it has room for")
    func standardLayoutFits() {
        for kind in CaptureKind.allCases {
            #expect(CardLayout.standard.actions(in: .column, for: kind).count <= CardLayout.columnCapacity)
        }
    }

    // MARK: - Finding the session behind a recording

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-card-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The lookup the card's availability depends on: a recording whose bytes are shared
    /// with a session finds it, and one that stands alone does not.
    @Test("A recording linked to a session finds it")
    func recordingFindsItsSession() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession.create(in: root, named: "carded")
        try session.create()
        try Data(repeating: 5, count: 512).write(to: session.screenURL)

        let recording = root.appendingPathComponent("Recording.mp4")
        try FileManager.default.linkItem(at: session.screenURL, to: recording)

        #expect(RecordingSessionStore(root: root).session(forFootageAt: recording) == session)
    }

    /// A recording made before the studio existed, or one whose session was swept, has to
    /// come back nil so the card hides the button rather than offering a dead one.
    @Test("A recording with no session finds nothing")
    func recordingWithoutSessionFindsNothing() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Standalone.mp4")
        try Data(repeating: 5, count: 512).write(to: recording)

        #expect(RecordingSessionStore(root: root).session(forFootageAt: recording) == nil)
    }

    @Test("A history recording with a session opens in the studio")
    func historyRecordingWithSessionOpensStudio() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession.create(in: root, named: "from-history")
        try session.create()
        try Data(repeating: 5, count: 512).write(to: session.screenURL)
        let recording = root.appendingPathComponent("Demo.mp4")
        try FileManager.default.linkItem(at: session.screenURL, to: recording)
        let store = RecordingSessionStore(root: root)
        let routed = HistoryOpenRouting.destination(kind: .video, fileURL: recording, store: store)
        guard case let .studio(directory) = routed else {
            Issue.record("expected a studio session, got \(routed)")
            return
        }
        #expect(directory.standardizedFileURL == session.directory.standardizedFileURL)
    }

    @Test("A screenshot from history stays on the overlay")
    func historyScreenshotStaysOnOverlay() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = root.appendingPathComponent("Shot.png")
        try Data(repeating: 1, count: 64).write(to: shot)
        let store = RecordingSessionStore(root: root)

        #expect(HistoryOpenRouting.destination(kind: .image, fileURL: shot, store: store) == .overlay)
    }

    @Test("A recording with no session stays on the overlay")
    func historyRecordingWithoutSessionStaysOnOverlay() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Old.mp4")
        try Data(repeating: 5, count: 512).write(to: recording)
        let store = RecordingSessionStore(root: root)

        #expect(
            HistoryOpenRouting.destination(kind: .video, fileURL: recording, store: store) == .overlay
        )
    }
}
