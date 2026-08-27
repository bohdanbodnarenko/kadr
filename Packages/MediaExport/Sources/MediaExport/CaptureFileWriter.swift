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
        let url = try availableURL(
            in: directory,
            template: template,
            context: context,
            fileExtension: options.format.fileExtension
        )

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }

        logger.info("Wrote \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// The first free filename for this capture.
    ///
    /// The counter goes through the template when it uses `{counter}` and is appended in
    /// parentheses when it does not, which matches what the Finder does.
    func availableURL(
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
