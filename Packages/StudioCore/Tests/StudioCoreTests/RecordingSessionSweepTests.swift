import Foundation
import Testing
@testable import StudioCore

/// Keeping the sessions folder from growing forever, without losing anybody's recording
/// (docs/09 U3.1).
///
/// The whole difficulty is in one distinction: a session whose footage is also the user's
/// own recording is redundant and can go, and a session whose footage is the *last* copy is
/// the recording and must not. Every test here is about that line.
@Suite("Recording session sweep")
struct RecordingSessionSweepTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-sweep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session with footage. `linkedFrom` gives the footage a second name, standing in
    /// for the user's own recording in their save folder.
    @discardableResult
    private func makeSession(
        in root: URL,
        named name: String,
        linkedFrom external: URL? = nil,
        modified: Date? = nil
    ) throws -> RecordingSession {
        let session = RecordingSession.create(in: root, named: name)
        try session.create()
        try Data(repeating: 9, count: 2048).write(to: session.screenURL)
        try SessionDocument(session: session).write(InputTelemetry())

        if let external {
            try FileManager.default.linkItem(at: session.screenURL, to: external)
        }
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: session.directory.path
            )
        }
        return session
    }

    // MARK: - The distinction the sweep rests on

    @Test("A session whose footage is also the user's recording is not the only copy")
    func linkedFootageIsNotTheOnlyCopy() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        let session = try makeSession(in: root, named: "linked", linkedFrom: recording)
        #expect(!session.holdsTheOnlyCopy)
    }

    @Test("A session whose footage has no other name is the only copy")
    func unlinkedFootageIsTheOnlyCopy() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "alone")
        #expect(session.holdsTheOnlyCopy)
    }

    /// The case that actually happens: the user records, then deletes the recording from
    /// their save folder months later. The session silently becomes the last copy.
    @Test("Deleting the user's recording makes the session the only copy")
    func deletingTheRecordingChangesTheAnswer() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        let session = try makeSession(in: root, named: "was-linked", linkedFrom: recording)
        #expect(!session.holdsTheOnlyCopy)

        try FileManager.default.removeItem(at: recording)
        #expect(session.holdsTheOnlyCopy, "the session is now the only place the footage exists")
    }

    @Test("A session with no footage at all is not counted as holding a copy")
    func emptySessionHoldsNothing() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession.create(in: root, named: "empty")
        try session.create()
        #expect(!session.holdsTheOnlyCopy)
    }

    // MARK: - Sweeping

    @Test("An aged-out session whose footage survives elsewhere is swept")
    func sweepsRedundantAndOld() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        let session = try makeSession(
            in: root,
            named: "old-linked",
            linkedFrom: recording,
            modified: Date(timeIntervalSinceNow: -60 * 24 * 60 * 60)
        )

        #expect(RecordingSessionStore(root: root).sweepExpired() == 1)
        #expect(!session.exists)
        #expect(
            FileManager.default.fileExists(atPath: recording.path),
            "sweeping the session took the user's recording with it"
        )
    }

    /// The assertion this whole design exists for. A cleanup routine that can delete a
    /// recording is not a cleanup routine.
    @Test("An aged-out session holding the only copy is kept")
    func neverSweepsTheLastCopy() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(
            in: root,
            named: "old-alone",
            modified: Date(timeIntervalSinceNow: -365 * 24 * 60 * 60)
        )

        #expect(RecordingSessionStore(root: root).sweepExpired() == 0)
        #expect(session.exists, "a year-old session holding the last copy was deleted anyway")
        #expect(session.hasFootage)
    }

    @Test("A recent session is kept even when its footage is redundant")
    func keepsRecentSessions() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        let session = try makeSession(in: root, named: "fresh", linkedFrom: recording)

        #expect(RecordingSessionStore(root: root).sweepExpired() == 0)
        #expect(session.exists)
    }

    /// A session edited last week is one somebody may edit again, so the clock runs from
    /// the last touch rather than from when it was recorded.
    @Test("Editing a session restarts its retention")
    func editingRestartsTheClock() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        let session = try makeSession(
            in: root,
            named: "touched",
            linkedFrom: recording,
            modified: Date(timeIntervalSinceNow: -60 * 24 * 60 * 60)
        )
        try SessionDocument(session: session).writeDraft(StudioEdit.untouched(duration: 3))

        #expect(RecordingSessionStore(root: root).sweepExpired() == 0)
        #expect(session.exists)
    }

    @Test("The retention window is respected", arguments: [1.0, 7.0, 90.0])
    func retentionIsHonoured(days: Double) throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let day: TimeInterval = 24 * 60 * 60
        let recording = root.appendingPathComponent("Recording.mp4")
        try makeSession(
            in: root,
            named: "aged",
            linkedFrom: recording,
            modified: Date(timeIntervalSinceNow: -(days + 1) * day)
        )
        let store = RecordingSessionStore(root: root)
        #expect(store.sweepExpired(olderThan: (days + 2) * day) == 0, "swept before its time")
        #expect(store.sweepExpired(olderThan: days * day) == 1)
    }

    // MARK: - Finding a session by its recording

    @Test("A recording finds the session that shares its bytes")
    func findsSessionByFootage() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        let session = try makeSession(in: root, named: "findable", linkedFrom: recording)

        let found = RecordingSessionStore(root: root).session(forFootageAt: recording)
        #expect(found == session)
    }

    /// Matching by inode rather than a remembered path is what makes this survive the user
    /// tidying their save folder.
    @Test("Renaming the recording does not lose its session")
    func survivesRenaming() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        let session = try makeSession(in: root, named: "renamed", linkedFrom: recording)

        let moved = root.appendingPathComponent("Something else.mp4")
        try FileManager.default.moveItem(at: recording, to: moved)

        #expect(RecordingSessionStore(root: root).session(forFootageAt: moved) == session)
    }

    @Test("A recording with no session finds nothing rather than the nearest one")
    func unrelatedRecordingFindsNothing() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        try makeSession(in: root, named: "unrelated", linkedFrom: recording)

        let other = root.appendingPathComponent("Different.mp4")
        try Data(repeating: 4, count: 2048).write(to: other)
        #expect(RecordingSessionStore(root: root).session(forFootageAt: other) == nil)
    }

    @Test("A file that does not exist finds nothing")
    func missingFileFindsNothing() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RecordingSessionStore(root: root).session(forFootageAt: root.appendingPathComponent("no.mp4")) == nil)
    }

    // MARK: - Reporting what it costs

    /// Charging shared footage to the session would tell somebody they can reclaim space
    /// that deleting the sessions does not reclaim — the bytes belong to their recording.
    @Test("A redundant session is charged only for its sidecar")
    func redundantSessionCostsAlmostNothing() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        try makeSession(in: root, named: "cheap", linkedFrom: recording)

        let store = RecordingSessionStore(root: root)
        #expect(store.exclusiveByteCount() < 2048, "the shared footage was counted against the session")
    }

    @Test("A last-copy session is charged for its footage")
    func lastCopySessionCostsItsFootage() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession(in: root, named: "expensive")
        #expect(RecordingSessionStore(root: root).exclusiveByteCount() >= 2048)
    }

    @Test("The sessions holding the only copy are the ones reported")
    func reportsLastCopySessions() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("Recording.mp4")
        try makeSession(in: root, named: "linked", linkedFrom: recording)
        let alone = try makeSession(in: root, named: "alone")

        let reported = RecordingSessionStore(root: root).sessionsHoldingTheOnlyCopy()
        #expect(reported.count == 1)
        #expect(reported.first == alone)
    }
}
