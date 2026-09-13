import CoreGraphics
import Foundation
import os
import Shared

/// Writes captures to disk (docs/03 §9).
///
/// Two rules from the spec are enforced here rather than left to call sites:
///
/// * **Atomic writes**, so a crash or a full disk never leaves a half-written PNG that
///   opens as a grey rectangle.
/// * **Never overwrite.** A name that is taken gets a counter, because a screenshot tool
///   that silently replaces yesterday's file is a data-loss bug.
public struct CaptureFileWriter: Sendable {
    private let encoder = ImageEncoder()
    private let logger = KadrLog.logger(.capture)

    /// `FileManager.default` is used directly rather than stored: it is not `Sendable`,
    /// and the handful of operations here are documented as thread-safe.
    private var fileManager: FileManager {
        .default
    }

    public init() {}

    /// Encodes and writes an image, returning where it landed.
    @discardableResult
    public func write(
        _ image: CGImage,
        to directory: URL,
        template: FilenameTemplate = .default,
        context: FilenameContext = FilenameContext(),
        options: EncodingOptions = EncodingOptions()
    ) throws -> URL {
        let data = try encoder.encode(image, options: options)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }

        // Both halves of docs/03 §9 — atomic, and never overwriting — in one move.
        //
        // Choosing a free name and then writing it is check-then-act: two captures a
        // millisecond apart pick the same name and the second replaces the first. Foundation
        // cannot express both guarantees in one write (`.withoutOverwriting` traps when
        // combined with `.atomic`), so the file is written to a scratch name in the same
        // directory and *moved* into place: the rename is atomic, and it fails rather than
        // replacing anything, which makes the move itself the arbiter of the race
        // (docs/07 M6).
        //
        // Same directory deliberately: a move across volumes is a copy, and would be
        // neither atomic nor cheap.
        let temporary = directory.appendingPathComponent(".kadr-write-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        // Only ever removes a scratch file the move did not consume.
        defer { try? fileManager.removeItem(at: temporary) }

        for _ in 1 ... Self.collisionRetries {
            let url = try availableURL(
                in: directory,
                template: template,
                context: context,
                fileExtension: options.format.fileExtension
            )
            do {
                try fileManager.moveItem(at: temporary, to: url)
                logger.info("Wrote \(url.lastPathComponent, privacy: .public)")
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
        }
        throw ExportError.writeFailed("Could not claim a filename in \(directory.path)")
    }

    /// Encodes and writes to a path the user picked (CleanShot §8.5).
    ///
    /// The save panel has already confirmed a replace, so this overwrites rather than
    /// picking a free name — a Save As that refused the path the user just confirmed
    /// would look broken.
    public func write(_ image: CGImage, to url: URL, options: EncodingOptions = EncodingOptions()) throws {
        let data = try encoder.encode(image, options: options)
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        let temporary = directory.appendingPathComponent(".kadr-write-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        do {
            try fileManager.moveItem(at: temporary, to: url)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        logger.info("Wrote \(url.lastPathComponent, privacy: .public)")
    }

    /// How many times a lost filename race is retried before giving up. Generous: every
    /// retry means another capture landed in the same millisecond.
    private static let collisionRetries = 16

    /// The first free filename for this capture.
    ///
    /// The counter goes through the template when it uses `{counter}` and is appended in
    /// parentheses when it does not, which matches what the Finder does.
    public func availableURL(
        in directory: URL,
        template: FilenameTemplate,
        context: FilenameContext,
        fileExtension: String
    ) throws -> URL {
        var context = context
        let usesCounter = template.pattern.lowercased().contains("{counter}")

        // Bounded so a permissions problem cannot spin forever.
        for attempt in 1 ... 10000 {
            context.counter = attempt
            let base = template.expand(context)
            let name = attempt == 1 || usesCounter ? base : "\(base) (\(attempt))"
            let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        throw ExportError.writeFailed("Could not find an unused filename in \(directory.path)")
    }
}
