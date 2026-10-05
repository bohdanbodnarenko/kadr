import AppKit
import Foundation
import os
import RecordingCore
import Shared
import StudioSession

/// Turns leftover recording segments into playable History items (docs/03 §1.8).
///
/// A clean stop deletes the temporary `Kadr-Recording-*` folder. A crash leaves the
/// segments on disk. Launch stitches what AVFoundation can still open, writes the
/// capture sidecar the studio needs, and hands the movie to the same overlay path as a
/// normal stop.
@MainActor
enum RecordingCrashRecovery {
    private static let logger = KadrLog.logger(.recording)

    /// Recovers interrupted recordings, then returns how many movies were restored.
    static func recover(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        inProgressDirectory: URL = InterruptedRecordingStore.inProgressRoot(),
        saveFolder: URL,
        sessions: RecordingSessionStore? = StudioSessionRecorder.store(),
        present: (URL) -> Void,
        unrecoverable: (URL) -> Void = { _ in }
    ) async -> Int {
        var restored = 0
        restored += await recoverAbandonedSegments(
            in: [temporaryDirectory, inProgressDirectory],
            saveFolder: saveFolder,
            sessions: sessions,
            present: present,
            unrecoverable: unrecoverable
        )
        restored += await recoverSessionsMissingManifests(sessions: sessions, present: present)
        return restored
    }

    static func announce(_ count: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = count == 1
            ? "Recovered an interrupted recording"
            : "Recovered \(count) interrupted recordings"
        alert.informativeText = "The playable footage was preserved in History and can be opened in Studio."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Says once that footage could not be recovered, and where it is (docs/18 REC-4).
    static func announceUnrecoverable(_ directories: [URL]) {
        guard !directories.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = directories.count == 1
            ? "Kadr could not recover an interrupted recording"
            : "Kadr could not recover \(directories.count) interrupted recordings"
        alert.informativeText = "The footage could not be opened, so it was left where it is. "
            + "Kadr will not try again."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting(directories)
    }

    /// Left in a folder whose footage could not be recovered, so launch reports it once
    /// and stops retrying it (docs/18 REC-4).
    static let unrecoverableMarker = ".kadr-unrecoverable"

    private static func markUnrecoverable(_ directory: URL, report: (URL) -> Void) {
        let marker = directory.appendingPathComponent(unrecoverableMarker)
        guard FileManager.default.createFile(atPath: marker.path, contents: Data()) else { return }
        report(directory)
    }

    private static func recoverAbandonedSegments(
        in roots: [URL],
        saveFolder: URL,
        sessions: RecordingSessionStore?,
        present: (URL) -> Void,
        unrecoverable: (URL) -> Void
    ) async -> Int {
        var restored = 0
        for directory in InterruptedRecordingStore.directories(in: roots) {
            restored += await recoverSessionDirectory(
                directory,
                saveFolder: saveFolder,
                sessions: sessions,
                present: present,
                unrecoverable: unrecoverable
            ) ? 1 : 0
        }
        return restored
    }

    private static func recoverSessionDirectory(
        _ directory: URL,
        saveFolder: URL,
        sessions: RecordingSessionStore?,
        present: (URL) -> Void,
        unrecoverable: (URL) -> Void
    ) async -> Bool {
        // Already reported: the user was told where it is, and retrying unreadable
        // footage on every launch only costs time.
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(unrecoverableMarker).path) {
            return false
        }
        let segments = InterruptedRecordingStore.segmentFiles(in: directory)
        // A folder left by a quit during setup holds nothing that was ever recorded: no
        // segment, or only an empty one. Recovery used to skip it and keep it forever
        // (docs/12 §2, docs/17 T-REC-10). Non-empty but unreadable segments are still kept.
        if segments.allSatisfy(isEmptyFile) {
            try? FileManager.default.removeItem(at: directory)
            return false
        }
        let playable = await playableSegments(segments)
        guard !playable.isEmpty else {
            markUnrecoverable(directory, report: unrecoverable)
            return false
        }

        let destination = uniqueMovieURL(in: saveFolder)
        do {
            _ = try await SegmentStitcher().stitch(playable, to: destination)
        } catch {
            logger.error("Could not stitch recovered segments: \(error.localizedDescription, privacy: .public)")
            markUnrecoverable(directory, report: unrecoverable)
            return false
        }

        guard await adopt(
            destination,
            sessions: sessions,
            present: present,
            preferredSession: sessionLinked(from: directory, sessions: sessions)
        ) else { return false }
        try? FileManager.default.removeItem(at: directory)
        return true
    }

    private static func isEmptyFile(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size == 0
    }

    private static func playableSegments(_ segments: [URL]) async -> [URL] {
        var playable: [URL] = []
        for segment in segments {
            guard await VideoPosterFrame.duration(of: segment) != nil else { continue }
            playable.append(segment)
        }
        return playable
    }

    private static func recoverSessionsMissingManifests(
        sessions: RecordingSessionStore?,
        present: (URL) -> Void
    ) async -> Int {
        let needing = sessions?.sessionsNeedingCaptureRecovery() ?? []
        var restored = 0
        for session in needing {
            restored += await restoreManifest(for: session, present: present)
        }
        return restored
    }

    private static func restoreManifest(for session: RecordingSession, present: (URL) -> Void) async -> Int {
        guard await writeManifest(for: session) else { return 0 }
        present(session.screenURL)
        return 1
    }

    private static func adopt(
        _ footage: URL,
        sessions: RecordingSessionStore?,
        present: (URL) -> Void,
        preferredSession: RecordingSession? = nil
    ) async -> Bool {
        let session = preferredSession
            ?? sessions?.sessionsWaitingForFootage().first
            ?? newSession(in: sessions?.root)
        if let session, attach(footage, to: session) {
            hydrateTelemetry(for: session)
            _ = await writeManifest(for: session)
        }
        present(footage)
        return true
    }

    private static func hydrateTelemetry(for session: RecordingSession) {
        guard !FileManager.default.fileExists(atPath: session.inputURL.path) else { return }
        let chunk = TelemetryJournal(url: session.inputJournalURL).load()
        guard !chunk.isEmpty else { return }
        try? SessionDocument(session: session).write(InputTelemetry(
            pointer: chunk.pointer,
            clicks: chunk.clicks,
            keystrokes: chunk.keystrokes
        ))
    }

    private static func newSession(in root: URL?) -> RecordingSession? {
        guard let root else { return nil }
        let session = RecordingSession.create(in: root, named: recoveredName())
        do {
            try session.create()
            return session
        } catch {
            logger.error("Could not create a recovered session: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func writeManifest(for session: RecordingSession) async -> Bool {
        guard let duration = await VideoPosterFrame.duration(of: session.screenURL),
              let size = await VideoPosterFrame.pixelSize(of: session.screenURL)
        else { return false }
        let existing = SessionDocument(session: session).manifest()
        let scale = existing?.scale ?? ActiveScreen.resolve()?.backingScaleFactor ?? 2
        do {
            try SessionDocument(session: session).write(CaptureManifest(
                pixelSize: CGSize(width: size.width, height: size.height),
                scale: scale,
                frameRate: existing?.frameRate ?? 60,
                duration: duration,
                hasBakedCursor: existing?.hasBakedCursor ?? true,
                hasCamera: session.hasCameraFile
            ))
            return true
        } catch {
            logger.error("Could not write a recovered manifest: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func attach(_ footage: URL, to session: RecordingSession) -> Bool {
        let manager = FileManager.default
        try? manager.removeItem(at: session.screenURL)
        do {
            try manager.linkItem(at: footage, to: session.screenURL)
            return true
        } catch {
            do {
                try manager.copyItem(at: footage, to: session.screenURL)
                session.markFootageAsCopy()
                return true
            } catch {
                logger.error("Could not attach recovered footage: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    private static func sessionLinked(from directory: URL, sessions _: RecordingSessionStore?) -> RecordingSession? {
        let link = directory.appendingPathComponent("session.link")
        guard let path = try? String(contentsOf: link, encoding: .utf8) else { return nil }
        let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return RecordingSession(directory: url)
    }

    private static func uniqueMovieURL(in folder: URL) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Kadr Recovered \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(index).mp4")
            index += 1
        }
        return url
    }

    private static func recoveredName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(formatter.string(from: Date()))-recovered"
    }
}
