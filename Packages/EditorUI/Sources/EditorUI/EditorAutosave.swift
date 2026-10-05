import AnnotationModel
import CryptoKit
import Foundation
import os
import Shared

/// Keeps a recoverable copy of an editing session (docs/03 §3, docs/07 M7).
///
/// The editor is a separate process that exits when its last window closes, and until now
/// closing a window threw the annotations away with no prompt and no copy. Two things fix
/// that: the window asks before discarding, and this — a `.kadr` written beside nothing,
/// in Application Support, updated as the user works.
///
/// The sidecar lives in Application Support rather than next to the capture because the
/// save folder is the user's, often a synced one, and a file that appears while they draw
/// and vanishes when they close is not a file they asked for. The name is derived from the
/// capture's path, so reopening the same capture finds the same autosave.
public struct EditorAutosave: Sendable {
    private let directory: URL
    private let logger = KadrLog.logger(.app)

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Kadr/Autosave", isDirectory: true)
    }

    /// Where the autosave for a capture lives: the annotations, rewritten on every save.
    ///
    /// Hashed rather than named: two captures in different folders can share a filename,
    /// and a path is not a filename.
    ///
    /// The base image sits beside it in its own file, written once per session: rewriting a
    /// whole `.kadr` 1.5 s after every edit re-wrote megabytes of unchanged pixels each
    /// time (docs/18 ED-10).
    public func url(for captureURL: URL) -> URL {
        stem(for: captureURL).appendingPathExtension("json")
    }

    private func stem(for captureURL: URL) -> URL {
        let path = captureURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private func baseURL(for captureURL: URL) -> URL {
        stem(for: captureURL).appendingPathExtension("base.png")
    }

    /// The single-file autosave earlier builds wrote, still read once so an update does
    /// not lose a crash's work.
    private func legacyURL(for captureURL: URL) -> URL {
        stem(for: captureURL).appendingPathExtension(KadrDocumentFile.fileExtension)
    }

    /// Whether there is recoverable work for this capture.
    public func hasAutosave(for captureURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(for: captureURL).path)
            || FileManager.default.fileExists(atPath: legacyURL(for: captureURL).path)
    }

    /// Where the note of which capture an autosave belongs to lives.
    ///
    /// The autosave's own name is a hash, and a hash does not invert. Rather than widen
    /// the `.kadr` format with a path — which would put the user's folder layout inside
    /// every project file they share — the origin is kept beside it.
    private func originURL(for captureURL: URL) -> URL {
        stem(for: captureURL).appendingPathExtension("origin")
    }

    /// Writes the current state. Overwrites the previous autosave, which is the point.
    ///
    /// The base image is written only when its checksum differs from the one on disk; the
    /// commands are written every time. Both atomically: an autosave interrupted halfway is
    /// worse than no autosave, because the user will be offered it and it will not open.
    public func write(_ contents: KadrDocumentFile.Contents, for captureURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = baseURL(for: captureURL)
        let checksumFile = stem(for: captureURL).appendingPathExtension("basecrc")
        let checksum = String(contents.baseImageCRC32 ?? KadrDocumentFile.crc32(of: contents.baseImagePNG))
        let stored = (try? Data(contentsOf: checksumFile)).map { String(decoding: $0, as: UTF8.self) }
        if stored != checksum || !manager.fileExists(atPath: base.path) {
            try contents.baseImagePNG.write(to: base, options: .atomic)
            try Data(checksum.utf8).write(to: checksumFile, options: .atomic)
        }
        try KadrDocumentFile.commandsJSON(for: contents.document)
            .write(to: url(for: captureURL), options: .atomic)
        try? manager.removeItem(at: legacyURL(for: captureURL))
        try? Data(captureURL.standardizedFileURL.path.utf8)
            .write(to: originURL(for: captureURL), options: .atomic)
    }

    /// Reads back recoverable work, or nil if there is none to read.
    public func read(for captureURL: URL) -> KadrDocumentFile.Contents? {
        let commands = url(for: captureURL)
        let legacy = legacyURL(for: captureURL)
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: commands.path) {
                return try KadrDocumentFile.contents(
                    commandsJSON: Data(contentsOf: commands),
                    baseImagePNG: Data(contentsOf: baseURL(for: captureURL))
                )
            }
            guard manager.fileExists(atPath: legacy.path) else { return nil }
            return try KadrDocumentFile.read(from: legacy)
        } catch {
            // A corrupt autosave is not worth surfacing: it is a copy, the capture itself
            // is intact, and offering to restore something unreadable helps nobody.
            logger.error("Discarding an unreadable autosave: \(error.localizedDescription, privacy: .public)")
            discard(for: captureURL)
            return nil
        }
    }

    /// Removes the autosave, once the work it protected is safe or deliberately dropped.
    public func discard(for captureURL: URL) {
        let files = [
            url(for: captureURL), baseURL(for: captureURL), legacyURL(for: captureURL),
            stem(for: captureURL).appendingPathExtension("basecrc"), originURL(for: captureURL)
        ]
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes autosaves whose capture no longer exists, and returns how many went.
    ///
    /// Without this, deleting a capture leaves its annotations in Application Support
    /// indefinitely — the same "deleted means deleted" problem the library had (docs/07 H5).
    @discardableResult
    public func sweepOrphans(
        captureExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Int {
        var removed = 0
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        for note in contents where note.pathExtension == "origin" {
            let capture = (try? Data(contentsOf: note)).flatMap { String(data: $0, encoding: .utf8) }
            guard let capture, !captureExists(URL(fileURLWithPath: capture)) else { continue }
            discard(for: URL(fileURLWithPath: capture))
            try? FileManager.default.removeItem(at: note)
            removed += 1
        }
        if removed > 0 {
            logger.info("Swept \(removed, privacy: .public) orphaned autosave(s)")
        }
        return removed
    }
}
