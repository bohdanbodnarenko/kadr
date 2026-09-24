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
    /// Why the save folder refused the file, when the policy asked to save there and the
    /// capture was staged instead (docs/17 T-OUT-6). `nil` when nothing went wrong.
    public var saveFailure: String?

    public init(
        fileURL: URL? = nil,
        isStaged: Bool = false,
        copiedToClipboard: Bool = false,
        saveFailure: String? = nil
    ) {
        self.fileURL = fileURL
        self.isStaged = isStaged
        self.copiedToClipboard = copiedToClipboard
        self.saveFailure = saveFailure
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
            do {
                result.fileURL = try write(
                    data,
                    to: saveFolder,
                    template: template,
                    context: context,
                    options: options
                )
            } catch {
                // An unmounted drive, a read-only folder or a full disk must not cost the
                // user the capture: stage it and say why, so the card can offer another
                // folder (docs/17 T-OUT-6). Only if staging fails too is it lost.
                logger.error("Save folder refused the capture; staging it: \(error.localizedDescription, privacy: .public)")
                try staging.prepare()
                result.fileURL = try write(
                    data,
                    to: staging.directory,
                    template: template,
                    context: context,
                    options: options
                )
                result.isStaged = true
                result.saveFailure = (error as? ExportError).flatMap {
                    if case let .writeFailed(reason) = $0 { reason } else { nil }
                } ?? error.localizedDescription
            }
        }

        return result
    }

    /// A free path in the staging area for a file this exporter is not going to write.
    ///
    /// The scrolling stitcher writes its own PNG, in the helper process, and hands back a
    /// path — but the result should still land in staging and be finalised on the user's
    /// first action like any other capture (docs/03 §1.6, §2). So the naming and the
    /// collision handling stay here, and only the bytes come from somewhere else.
    public func stagingDestination(
        template: FilenameTemplate = .default,
        context: FilenameContext = FilenameContext(),
        fileExtension: String = "png"
    ) throws -> URL {
        try staging.prepare()
        return try writer.availableURL(
            in: staging.directory,
            template: template,
            context: context,
            fileExtension: fileExtension
        )
    }

    /// Moves a staged capture into the save folder on the user's first action (docs/03 §2).
    @discardableResult
    public func finalizeStaged(_ url: URL, into folder: URL) throws -> URL {
        try staging.finalize(url, into: folder)
    }

    /// Moves a staged capture to a path the user picked (CleanShot §6.2).
    @discardableResult
    public func finalizeStaged(_ url: URL, to destination: URL) throws -> URL {
        try staging.finalize(url, to: destination)
    }

    /// Copies a file Kadr does not own into staging under `filename` (docs/17 T-OUT-5).
    public func adoptCopy(of url: URL, named filename: String) throws -> URL {
        try staging.adoptCopy(of: url, named: filename)
    }

    /// Whether this file is still sitting in staging (docs/07 M11).
    public func isStaged(_ url: URL) -> Bool {
        staging.contains(url)
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
