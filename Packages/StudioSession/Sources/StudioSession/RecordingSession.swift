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

    /// Two sessions are the same session when they are the same directory.
    ///
    /// Compared by resolved path rather than by `URL`, because the same directory has many
    /// URLs: `/var` against `/private/var`, a trailing slash or not, and whatever
    /// `contentsOfDirectory` hands back against whatever a caller constructed. Synthesised
    /// equality would call a session found by enumeration different from the one that was
    /// just created — which is exactly the comparison every lookup here performs.
    public static func == (lhs: RecordingSession, rhs: RecordingSession) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    private var identity: String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
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

    /// Append-only chunks flushed while the recording is running (docs/10 R2.5).
    public var inputJournalURL: URL {
        directory.appendingPathComponent("input.jsonl")
    }

    /// What was being recorded: the display, the window, the geometry per frame.
    public var captureURL: URL {
        directory.appendingPathComponent("capture.json")
    }

    /// Present when the footage was copied onto this volume rather than hard-linked
    /// (docs/10 R3.5).
    ///
    /// A copy always has `referenceCount == 1`, so the usual "only copy" test would treat
    /// every external-disk recording as unsweepable. The marker is the evidence that an
    /// original exists elsewhere.
    public var copyMarkerURL: URL {
        directory.appendingPathComponent("copied.flag")
    }

    /// Records that `screen.mov` is a copy, not a hard link to the user's recording.
    public func markFootageAsCopy() {
        FileManager.default.createFile(atPath: copyMarkerURL.path, contents: Data())
    }

    /// Whether the footage was copied across volumes rather than linked.
    public var footageIsACopy: Bool {
        FileManager.default.fileExists(atPath: copyMarkerURL.path)
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

    /// The persisted transcript, versioned like every other sidecar (docs/13 T1.3).
    public var transcriptURL: URL {
        directory.appendingPathComponent("transcript.json")
    }

    /// Base name for an imported soundtrack. The picked file is copied in with its own
    /// extension so a WAV stays a WAV; only one soundtrack lives here at a time.
    public static let soundtrackBaseName = "soundtrack"

    /// Imported replacement audio files currently in this session.
    public var soundtrackURLs: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.deletingPathExtension().lastPathComponent == Self.soundtrackBaseName
        }.map(\.standardizedFileURL)
    }

    /// The soundtrack named in `edit`, if that file is still here.
    public func soundtrackURL(for edit: StudioEdit) -> URL? {
        guard let name = edit.soundtrackFileName, !name.isEmpty else { return nil }
        let url = directory
            .appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies `url` in as the session's soundtrack, replacing any previous import.
    public func replaceSoundtrack(copying url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let fileName = "\(Self.soundtrackBaseName).\(ext.isEmpty ? "m4a" : ext)"
        let destination = directory.appendingPathComponent(fileName)
        try removeSoundtracks()
        try FileManager.default.copyItem(at: url, to: destination)
        return fileName
    }

    public func removeSoundtracks() throws {
        for existing in soundtrackURLs {
            try FileManager.default.removeItem(at: existing)
        }
    }

    /// Base name for an imported canvas wallpaper. Copied in with its own extension.
    public static let wallpaperBaseName = "wallpaper"

    /// Imported wallpaper files currently in this session.
    public var wallpaperURLs: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.deletingPathExtension().lastPathComponent == Self.wallpaperBaseName
        }.map(\.standardizedFileURL)
    }

    /// The wallpaper named in `edit`, if that file is still here.
    public func wallpaperURL(for edit: StudioEdit) -> URL? {
        guard let name = edit.canvas.wallpaperFileName, !name.isEmpty else { return nil }
        let url = directory
            .appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies `url` in as the session's wallpaper, replacing any previous import.
    public func replaceWallpaper(copying url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let fileName = "\(Self.wallpaperBaseName).\(ext.isEmpty ? "png" : ext)"
        let destination = directory.appendingPathComponent(fileName)
        try removeWallpapers()
        try FileManager.default.copyItem(at: url, to: destination)
        return fileName
    }

    public func removeWallpapers() throws {
        for existing in wallpaperURLs {
            try FileManager.default.removeItem(at: existing)
        }
    }

    /// Every file a session may contain, for sweeps and size reporting.
    public var allURLs: [URL] {
        [
            screenURL, cameraURL, inputURL, inputJournalURL, captureURL,
            editURL, draftEditURL, renderStampURL, posterURL,
            // Was missing (docs/11 S2). Every caller of this treats it as "everything this
            // session owns" — deleting a session, measuring what it costs — so a file left
            // out is a file left behind on disk and a size that under-reports.
            copyMarkerURL,
            transcriptURL,
            projectURL
        ] + soundtrackURLs + wallpaperURLs
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

    /// Whether the camera file was written, even if the screen file never arrived.
    ///
    /// A crash mid-recording can leave the camera (and the telemetry journal) in the
    /// session before the screen movie is attached. Sweeping that package as empty would
    /// throw away the only surviving camera take.
    public var hasCameraFile: Bool {
        FileManager.default.fileExists(atPath: cameraURL.path)
    }

    /// Whether anything recorded was written into this package.
    public var hasMedia: Bool {
        hasFootage || hasCameraFile
    }

    /// Footage without a capture manifest: the recording finished attaching, then the
    /// process died before the sidecar that names duration and size was written.
    public var needsCaptureRecovery: Bool {
        hasFootage && !FileManager.default.fileExists(atPath: captureURL.path)
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

    /// Whether this session holds the only copy of its footage.
    ///
    /// The footage is hard-linked from the user's own recording, so while both exist the
    /// bytes have two names and deleting either keeps the other. Once the user deletes
    /// theirs, this becomes the last link — and deleting the session would destroy the
    /// recording itself.
    ///
    /// Which is why the sweep asks. Reclaiming disk is worth doing; it is not worth doing
    /// at the price of silently throwing away somebody's only copy of something they
    /// recorded, and the difference between the two cases is one number the filesystem
    /// already keeps.
    public var holdsTheOnlyCopy: Bool {
        guard hasFootage else { return false }
        // A cross-volume copy is not the original. Age-based sweep is allowed; keeping it
        // forever because the copy's link count is 1 is how Application Support grew
        // without bound (docs/10 R3.5).
        if footageIsACopy {
            return false
        }
        let links = (try? FileManager.default.attributesOfItem(atPath: screenURL.path)[.referenceCount]) as? Int
        // No answer means no evidence the footage is safe elsewhere, so it is treated as
        // the last copy: the cautious reading is the one that cannot lose anything.
        return (links ?? 1) <= 1
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }

    public var byteCount: Int {
        allURLs.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// What this session costs beyond the footage: the telemetry, the edit, the poster.
    ///
    /// Kilobytes, always. Worth measuring separately because when the footage is shared
    /// with the user's own recording this is the session's entire real cost, and quoting
    /// the footage as well would overstate it by three orders of magnitude.
    public var sidecarByteCount: Int {
        allURLs
            .filter { url in
                url != screenURL && url != cameraURL
                    && url.deletingPathExtension().lastPathComponent != Self.soundtrackBaseName
                    && url.deletingPathExtension().lastPathComponent != Self.wallpaperBaseName
            }
            .reduce(0) { total, url in
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

    /// Sessions whose footage is present but whose capture sidecar never landed.
    public func sessionsNeedingCaptureRecovery() -> [RecordingSession] {
        sessions().filter(\.needsCaptureRecovery)
    }

    /// Sessions that started capturing and never received a screen file.
    public func sessionsWaitingForFootage() -> [RecordingSession] {
        sessions().filter { !$0.hasFootage && $0.exists }
    }

    /// Removes sessions with no footage in them.
    ///
    /// A directory created for a recording that failed before writing a frame is litter;
    /// one with footage is somebody's work, and is never swept on age alone.
    @discardableResult
    public func sweepEmpty() -> Int {
        var removed = 0
        for session in sessions() where !session.hasMedia {
            try? session.delete()
            removed += 1
        }
        if removed > 0 {
            logger.info("Swept \(removed, privacy: .public) empty recording session(s)")
        }
        return removed
    }

    /// How long a session is kept after its footage stops being needed here.
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Removes sessions that have aged out and whose footage survives elsewhere.
    ///
    /// Two conditions, and both are necessary. Age, because a session somebody edited last
    /// week is one they may edit again. And redundancy — the footage must still be linked
    /// from the user's own recording — because a session that holds the last copy *is* the
    /// recording, and a cleanup routine that deletes recordings is not a cleanup routine.
    ///
    /// The consequence is deliberate: delete your recording from the save folder and its
    /// session is kept indefinitely rather than swept. That is unbounded in principle, and
    /// it is the right way round. Disk is recoverable; the recording is not, and the user
    /// can clear them explicitly.
    @discardableResult
    public func sweepExpired(olderThan retention: TimeInterval = defaultRetention, now: Date = Date()) -> Int {
        var removed = 0
        for session in sessions() where session.hasFootage {
            guard now.timeIntervalSince(modified(session.directory)) > retention else { continue }
            guard !session.holdsTheOnlyCopy else { continue }
            try? session.delete()
            removed += 1
        }
        if removed > 0 {
            logger.info("Swept \(removed, privacy: .public) expired recording session(s)")
        }
        return removed
    }

    /// The session whose footage is this file, if there is one.
    ///
    /// Matched by inode rather than by a stored path. The hard link *is* the relationship,
    /// so asking the filesystem is both cheaper than maintaining a mapping and correct in
    /// the case a mapping gets wrong: the user moving or renaming their recording within
    /// the volume keeps the link, and a remembered path would not.
    public func session(forFootageAt url: URL) -> RecordingSession? {
        guard let identifier = Self.fileIdentifier(url) else { return nil }
        return sessions().first { session in
            Self.fileIdentifier(session.screenURL) == identifier
        }
    }

    /// Project titles keyed by the footage file's standardised path, from one directory walk.
    public func displayNames(forFootageAt urls: [URL]) -> [String: String] {
        let sessions = sessions()
        var byIdentity: [Pair: String] = [:]
        for session in sessions {
            if let identity = Self.fileIdentifier(session.screenURL) {
                byIdentity[identity] = session.displayName
            }
        }
        var names: [String: String] = [:]
        for url in urls {
            if let identity = Self.fileIdentifier(url), let name = byIdentity[identity] {
                names[url.standardizedFileURL.path] = name
            }
        }
        return names
    }

    /// Every session that holds the only copy of its footage.
    ///
    /// What Settings shows before offering to remove them, because "this will delete four
    /// recordings you have no other copy of" is the sentence that has to appear.
    public func sessionsHoldingTheOnlyCopy() -> [RecordingSession] {
        sessions().filter(\.holdsTheOnlyCopy)
    }

    /// What every session is costing, counting shared bytes once.
    ///
    /// Footage that is still linked from the user's recording is not charged here: those
    /// bytes exist because the user has a recording, not because Kadr kept a session, and
    /// reporting them would tell somebody they can reclaim space that deleting the sessions
    /// would not reclaim.
    public func exclusiveByteCount() -> Int {
        sessions().reduce(0) { total, session in
            total + (session.holdsTheOnlyCopy ? session.byteCount : session.sidecarByteCount)
        }
    }

    /// The volume-unique identity of a file, for matching hard links.
    private static func fileIdentifier(_ url: URL) -> Pair? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? Int,
              let device = attributes[.systemNumber] as? Int
        else {
            return nil
        }
        // Both halves: inode numbers are unique per volume, not per machine, so two files
        // on different disks can share one.
        return Pair(device: device, inode: inode)
    }

    private struct Pair: Hashable {
        let device: Int
        let inode: Int
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
