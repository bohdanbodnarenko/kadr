import Foundation
import os
import Shared

/// Where a recording session keeps everything it knows (docs/09 U3.1).
///
/// A directory, not a file. A studio recording is several streams that have to stay in
/// step — the screen, the camera, what the pointer did, what the user then edited — and a
/// single container would mean rewriting the whole thing to change one number. A directory
/// lets the edit be saved in milliseconds while the footage is untouched.
///
/// It lives in Application Support rather than the temporary directory, and that is a
/// deliberate correction of the obvious choice: `/tmp` is purged on a schedule nobody
/// controls, and handing a user's unfinished recording to the purger is not a risk worth
/// taking for a folder that costs nothing to manage.
public struct RecordingSession: Sendable, Hashable {
    /// The package's extension. A recording session is Kadr's own format.
    public static let fileExtension = "kadrrec"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A new session under `root`, named for when it started.
    ///
    /// - Parameter timestamp: passed in rather than read, so a caller can name a session
    ///   deterministically and so nothing here depends on the clock.
    public static func create(in root: URL, named name: String) -> RecordingSession {
        RecordingSession(
            directory: root
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)
        )
    }

    /// Where sessions live: alongside everything else Kadr owns.
    public static func defaultRoot(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Kadr/Recordings", isDirectory: true)
    }

    // MARK: - The parts

    /// The screen recording itself.
    public var screenURL: URL {
        directory.appendingPathComponent("screen.mov")
    }

    /// The webcam, recorded separately so the editor can move, resize and remove it
    /// without re-encoding the screen (docs/09 U3.4).
    public var cameraURL: URL {
        directory.appendingPathComponent("camera.mov")
    }

    /// What the pointer and keyboard did, in recording time.
    public var inputURL: URL {
        directory.appendingPathComponent("input.json")
    }

    /// What was being recorded: the display, the window, the geometry per frame.
    public var captureURL: URL {
        directory.appendingPathComponent("capture.json")
    }

    /// The edit the user has committed.
    public var editURL: URL {
        directory.appendingPathComponent("edit.json")
    }

    /// The edit as it stands right now, saved continuously.
    ///
    /// Separate from `edit.json` on purpose. An autosave that overwrote the committed edit
    /// would make "revert" impossible and would turn a crash mid-drag into a permanent
    /// change; keeping them apart means the draft can be thrown away without losing
    /// anything the user chose.
    public var draftEditURL: URL {
        directory.appendingPathComponent("edit.draft.json")
    }

    /// Proof that a rendered export matches the edit that produced it (docs/09 U3.1).
    public var renderStampURL: URL {
        directory.appendingPathComponent("render.json")
    }

    /// A still for the card and the library.
    public var posterURL: URL {
        directory.appendingPathComponent("poster.jpg")
    }

    /// Every file a session may contain, for sweeps and size reporting.
    public var allURLs: [URL] {
        [screenURL, cameraURL, inputURL, captureURL, editURL, draftEditURL, renderStampURL, posterURL]
    }

    // MARK: - Lifecycle

    public func create() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    /// Whether there is footage here worth recovering.
    ///
    /// The screen recording is the test: an edit without footage is nothing, and footage
    /// without an edit is a perfectly good recording somebody has not edited yet.
    public var hasFootage: Bool {
        FileManager.default.fileExists(atPath: screenURL.path)
    }

    /// Whether this session was left behind by a crash (docs/09 U3.1).
    ///
    /// A session with footage and a draft but no committed edit is one that was open when
    /// something went wrong. A session with a committed edit was, at some point, finished
    /// with — reopening it is the user's business rather than a recovery.
    public var needsRecovery: Bool {
        hasFootage
            && FileManager.default.fileExists(atPath: draftEditURL.path)
            && !FileManager.default.fileExists(atPath: editURL.path)
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }

    public var byteCount: Int {
        allURLs.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// Finds sessions and the ones that need rescuing (docs/09 U3.1).
public struct RecordingSessionStore: Sendable {
    private let logger = KadrLog.logger(.recording)
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Every session under the root, newest first.
    public func sessions() -> [RecordingSession] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return contents
            .filter { $0.pathExtension == RecordingSession.fileExtension }
            .map(RecordingSession.init(directory:))
            .sorted { left, right in
                modified(left.directory) > modified(right.directory)
            }
    }

    /// Sessions a crash left open.
    public func sessionsNeedingRecovery() -> [RecordingSession] {
        sessions().filter(\.needsRecovery)
    }

    /// Removes sessions with no footage in them.
    ///
    /// A directory created for a recording that failed before writing a frame is litter;
    /// one with footage is somebody's work, and is never swept on age alone.
    @discardableResult
    public func sweepEmpty() -> Int {
        var removed = 0
        for session in sessions() where !session.hasFootage {
            try? session.delete()
            removed += 1
        }
        if removed > 0 {
            logger.info("Swept \(removed, privacy: .public) empty recording session(s)")
        }
        return removed
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
