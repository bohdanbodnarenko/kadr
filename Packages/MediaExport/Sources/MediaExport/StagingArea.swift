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

        var destination = folder.appendingPathComponent(url.lastPathComponent)
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder
                .appendingPathComponent("\(base) (\(counter))")
                .appendingPathExtension(ext)
            counter += 1
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return destination
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
