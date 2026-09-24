import Foundation
import os
import Shared

/// Where captures live before the user decides what to do with them (docs/03 §2).
///
/// Overlay-only mode is the reason this exists: the capture has to be a real file so it
/// can be dragged out, but it must not land on the Desktop until the user acts on it.
/// The staging directory is that middle ground, and it is swept on launch so an app that
/// crashed mid-session does not leak screenshots into Application Support forever.
public struct StagingArea: Sendable {
    private let logger = KadrLog.logger(.history)

    public let directory: URL

    /// How long an untouched staged file survives.
    public let retention: TimeInterval

    public init(directory: URL? = nil, retention: TimeInterval = 24 * 60 * 60) {
        self.directory = directory ?? Self.defaultDirectory
        self.retention = retention
    }

    /// `~/Library/Application Support/Kadr/Staging` (docs/04 §9).
    public static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Kadr", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Moves a staged file to its real home, keeping the name free (docs/03 §2).
    @discardableResult
    public func finalize(_ url: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        // The move itself is the collision check: `moveItem` refuses to replace, so a
        // second capture finalising between the test and the move loses the race rather
        // than the file. Testing first and moving after is how a capture gets overwritten
        // (the docs/07 M6 pattern).
        for counter in 1 ... Self.collisionRetries {
            let name = counter == 1 ? base : "\(base) (\(counter))"
            let destination = folder.appendingPathComponent(name).appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
        }
        throw ExportError.writeFailed("Could not find a free name in \(folder.lastPathComponent)")
    }

    /// Moves a staged file to a path the user picked (CleanShot §6.2 / §7).
    ///
    /// The save panel has already confirmed a replace, so an existing file at
    /// `destination` is removed first rather than getting a counter suffix.
    @discardableResult
    public func finalize(_ url: URL, to destination: URL) throws -> URL {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if url.standardizedFileURL == destination.standardizedFileURL {
            return destination
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return destination
    }

    /// Copies a file the user owns — or the History library does — into staging, so a
    /// transform or an edit can work on Kadr's own copy (docs/17 T-OUT-5).
    @discardableResult
    public func adoptCopy(of url: URL, named filename: String) throws -> URL {
        try prepare()
        return try Self.copy(url, named: filename, into: directory)
    }

    /// Copies `url` into `folder` as `filename`, taking the next free "name (2)" rather than
    /// replacing anything (docs/03 §9).
    ///
    /// The copy is the collision check, as in `finalize(_:into:)`: `copyItem` refuses to
    /// replace, so a race loses a name rather than a file.
    @discardableResult
    public static func copy(_ url: URL, named filename: String, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let named = URL(fileURLWithPath: filename)
        let ext = named.pathExtension.isEmpty ? url.pathExtension : named.pathExtension
        let stem = named.pathExtension.isEmpty ? filename : named.deletingPathExtension().lastPathComponent
        let base = FilenameTemplate.sanitise(stem).isEmpty ? "Capture" : FilenameTemplate.sanitise(stem)

        for counter in 1 ... collisionRetries {
            let name = counter == 1 ? base : "\(base) (\(counter))"
            let destination = folder.appendingPathComponent(name).appendingPathExtension(ext)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
        }
        throw ExportError.writeFailed("Could not find a free name in \(folder.lastPathComponent)")
    }

    /// How many names to try before giving up. Reached only if something is creating files
    /// as fast as we can name them.
    private static let collisionRetries = 32

    /// Whether `url` is a file this staging area is holding.
    ///
    /// Automation names files by path, so the only way to know whether `kadr pin --path …`
    /// points at a staged capture — one the 24-hour sweep would delete out from under the
    /// pin — is to ask (docs/07 M11).
    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path
            == directory.standardizedFileURL.path
    }

    /// Deletes staged files older than the retention window.
    ///
    /// Returns how many went, so launch can log it rather than deleting silently.
    @discardableResult
    public func sweep(now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > retention else { continue }
            if (try? manager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            logger.info("Swept \(removed, privacy: .public) stale staged capture(s)")
        }
        return removed
    }
}
