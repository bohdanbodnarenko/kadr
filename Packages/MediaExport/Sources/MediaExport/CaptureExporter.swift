import CoreGraphics
import Foundation
import os
import Shared

/// What should happen to a capture once it exists (docs/03 §2, §8.3).
public struct ExportPolicy: Sendable, Hashable {
    public var copiesToClipboard: Bool
    public var savesToFolder: Bool
    /// Write to the staging area instead of the save folder, and finalise later.
    public var staging: Bool

    public init(copiesToClipboard: Bool, savesToFolder: Bool, staging: Bool) {
        self.copiesToClipboard = copiesToClipboard
        self.savesToFolder = savesToFolder
        self.staging = staging
    }
}

/// Where a capture ended up.
public struct ExportResult: Sendable, Hashable {
    /// The file on disk, if one was written.
    public var fileURL: URL?
    /// True when that file is in the staging area rather than the save folder.
    public var isStaged: Bool
    public var copiedToClipboard: Bool

    public init(fileURL: URL? = nil, isStaged: Bool = false, copiedToClipboard: Bool = false) {
        self.fileURL = fileURL
        self.isStaged = isStaged
        self.copiedToClipboard = copiedToClipboard
    }
}

/// Puts a capture on the clipboard, on disk, or both, according to policy.
///
/// The clipboard half is a closure rather than a direct `NSPasteboard` call so this stays
/// AppKit-free and testable: MediaExport has no business owning the pasteboard, and a
/// test has no business writing to the user's real one.
public struct CaptureExporter: Sendable {
    private let encoder = ImageEncoder()
    private let writer = CaptureFileWriter()
    private let staging: StagingArea
    private let logger = KadrLog.logger(.capture)

    public init(staging: StagingArea = StagingArea()) {
        self.staging = staging
    }

    /// Exports one capture.
    ///
    /// - Parameter copyData: receives the encoded bytes when the policy asks for a
    ///   clipboard copy, and reports whether it succeeded.
    public func export(
        _ image: CGImage,
        policy: ExportPolicy,
        saveFolder: URL,
        template: FilenameTemplate = .default,
        context: FilenameContext = FilenameContext(),
        options: EncodingOptions = EncodingOptions(),
        copyData: (Data, ImageFormat) -> Bool = { _, _ in false }
    ) throws -> ExportResult {
        var result = ExportResult()

        // Encoded once, however many destinations there are.
        let data = try encoder.encode(image, options: options)

        if policy.copiesToClipboard {
            result.copiedToClipboard = copyData(data, options.format)
        }

        if policy.staging {
            try staging.prepare()
            result.fileURL = try write(
                data,
                to: staging.directory,
                template: template,
                context: context,
                options: options
            )
            result.isStaged = true
        } else if policy.savesToFolder {
            result.fileURL = try write(
                data,
                to: saveFolder,
                template: template,
                context: context,
                options: options
            )
        }

        return result
    }

    /// Moves a staged capture into the save folder on the user's first action (docs/03 §2).
    @discardableResult
    public func finalizeStaged(_ url: URL, into folder: URL) throws -> URL {
        try staging.finalize(url, into: folder)
    }

    /// Clears stale staged files. Called once at launch (docs/03 §2).
    @discardableResult
    public func sweepStaging() -> Int {
        staging.sweep()
    }

    private func write(
        _ data: Data,
        to directory: URL,
        template: FilenameTemplate,
        context: FilenameContext,
        options: EncodingOptions
    ) throws -> URL {
        let url = try writer.availableURL(
            in: directory,
            template: template,
            context: context,
            fileExtension: options.format.fileExtension
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        logger.info("Wrote \(url.lastPathComponent, privacy: .public)")
        return url
    }
}
