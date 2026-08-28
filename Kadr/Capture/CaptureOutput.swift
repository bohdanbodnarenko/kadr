import AppKit
import AutomationKit
import CaptureCore
import MediaExport
import os
import SettingsKit
import Shared
import UniformTypeIdentifiers

/// Applies the user's default-action policy to a finished capture (docs/03 §2, §8.3).
///
/// The full-resolution `CGImage` is passed in, encoded, and dropped: nothing here holds
/// onto it. That is rule 2 of doc 04 §7 — a 5K capture is roughly 59 MB decoded, and the
/// agent's entire idle budget is half of that, so full-res bitmaps must not survive the
/// export that consumed them.
@MainActor
struct CaptureOutput {
    private let settings: AppSettings
    private let exporter: CaptureExporter
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    init(settings: AppSettings, exporter: CaptureExporter = CaptureExporter()) {
        self.settings = settings
        self.exporter = exporter
    }

    /// Exports a capture according to the current settings.
    ///
    /// The full-resolution `CGImage` arrives, is encoded, and is gone when this returns:
    /// nothing here stores it (doc 04 §7 rule 2). `CaptureOutputMemoryTests` holds a weak
    /// reference across an export to prove it, which is the deterministic version of the
    /// "RSS returns to baseline" check.
    @discardableResult
    func deliver(_ capture: Capture, overrides: CaptureOverrides = .none) -> ExportResult? {
        let state = signposter.beginInterval("exportCapture")
        defer { signposter.endInterval("exportCapture", state) }

        do {
            return try exporter.export(
                capture.image,
                policy: policy(overrides),
                saveFolder: settings.saveFolder,
                template: FilenameTemplate(settings.filenameTemplate),
                context: context(for: capture),
                options: encodingOptions(for: capture),
                copyData: copyToClipboard
            )
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Exports a capture without blocking the main actor (docs/07 H4).
    ///
    /// Encoding a 5K capture is tens of megabytes of PNG work — hundreds of milliseconds
    /// of it — and doing that on the main actor freezes every window and blows the
    /// selection→clipboard budget that this method's own signpost measures. The encode and
    /// the file write happen off-main; only the pasteboard write comes back, because that
    /// is the one part AppKit wants on the main thread.
    @discardableResult
    func deliverOffMain(_ capture: Capture, overrides: CaptureOverrides = .none) async -> ExportResult? {
        let state = signposter.beginInterval("exportCapture")
        defer { signposter.endInterval("exportCapture", state) }

        let policy = policy(overrides)
        let request = ExportRequest(
            image: capture.image,
            policy: policy,
            saveFolder: settings.saveFolder,
            template: FilenameTemplate(settings.filenameTemplate),
            context: context(for: capture),
            options: encodingOptions(for: capture)
        )
        let exporter = exporter

        let outcome = await Task.detached(priority: .userInitiated) { () -> ExportOutcome? in
            let clipboard = ClipboardCapture()
            do {
                let result = try exporter.export(
                    request.image,
                    policy: request.policy,
                    saveFolder: request.saveFolder,
                    template: request.template,
                    context: request.context,
                    options: request.options,
                    copyData: { data, format in
                        clipboard.store(data, format: format)
                        return true
                    }
                )
                return ExportOutcome(result: result, clipboard: clipboard.taken)
            } catch {
                return nil
            }
        }.value

        guard let outcome else {
            logger.error("Export failed")
            return nil
        }
        if let clipboard = outcome.clipboard {
            _ = copyToClipboard(clipboard.data, format: clipboard.format)
        }
        return outcome.result
    }

    /// Exports several captures from one action, e.g. every display at once.
    ///
    /// Only the first goes to the clipboard: there is one pasteboard, and writing each
    /// display to it in turn means the user gets the last monitor rather than the one
    /// they were looking at (docs/07 M4). The rest are still written to disk, because
    /// losing three of four monitors would be worse than a file nobody asked for.
    func deliverOffMain(
        _ captures: [Capture],
        overrides: CaptureOverrides = .none
    ) async -> [(capture: Capture, result: ExportResult)] {
        var delivered: [(capture: Capture, result: ExportResult)] = []
        for (index, capture) in captures.enumerated() {
            var overrides = overrides
            if index > 0, overrides.action == nil || overrides.action == .copy {
                // Everything after the first saves rather than fighting for the clipboard.
                overrides.action = .save
            }
            if let result = await deliverOffMain(capture, overrides: overrides) {
                delivered.append((capture, result))
            }
        }
        return delivered
    }

    /// Moves a staged capture into the save folder on the user's first action.
    @discardableResult
    func finalizeStaged(_ url: URL) -> URL? {
        do {
            return try exporter.finalizeStaged(url, into: settings.saveFolder)
        } catch {
            logger.error("Could not finalise a staged capture: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether this path is a staged capture, which the 24-hour sweep will delete.
    func isStaged(_ url: URL) -> Bool {
        exporter.isStaged(url)
    }

    /// Where a file written by something other than the encoder should land.
    ///
    /// The scrolling stitcher runs in the helper and writes its own PNG (docs/03 §1.6), so
    /// it needs the path up front. It still goes to staging, gets the templated name, and
    /// is finalised on the user's first action exactly like any other capture.
    func stagingURL(pixelSize: PixelSize, applicationName: String? = nil) -> URL? {
        do {
            return try exporter.stagingDestination(
                template: FilenameTemplate(settings.filenameTemplate),
                context: FilenameContext(
                    applicationName: applicationName,
                    width: pixelSize.width,
                    height: pixelSize.height
                )
            )
        } catch {
            logger.error("Could not name a staged file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// What one export needs, gathered on the main actor so the work can leave it.
    private struct ExportRequest: @unchecked Sendable {
        let image: CGImage
        let policy: ExportPolicy
        let saveFolder: URL
        let template: FilenameTemplate
        let context: FilenameContext
        let options: EncodingOptions
    }

    private struct ExportOutcome: @unchecked Sendable {
        let result: ExportResult
        let clipboard: (data: Data, format: ImageFormat)?
    }

    /// Carries the encoded bytes back from the export so the pasteboard write can happen
    /// on the main actor, where AppKit wants it.
    ///
    /// `@unchecked Sendable` under a single-consumer invariant: it is written once inside
    /// the detached export and read once after that task has finished.
    private final nonisolated class ClipboardCapture: @unchecked Sendable {
        private(set) var taken: (data: Data, format: ImageFormat)?

        func store(_ data: Data, format: ImageFormat) {
            taken = (data, format)
        }
    }

    /// Clears stale staged files. Called once at launch (docs/03 §2).
    func sweepStaging() {
        exporter.sweepStaging()
    }

    // MARK: - Policy

    /// Every capture produces a file, whatever the policy.
    ///
    /// The Quick Access Overlay's whole point is dragging the capture into another app
    /// (docs/03 §2), and a drag needs something on disk. So a policy that does not save
    /// to the folder stages instead: the file exists, the Desktop stays clean, and it is
    /// finalised only if the user acts on it.
    private func policy(_ overrides: CaptureOverrides = .none) -> ExportPolicy {
        // An automated `action=` decides this capture only; the setting is untouched
        // (docs/03 §8.4). `annotate` and `pin` say what to do *with* the file rather than
        // where to put it, so they stage like the overlay-only policy does.
        if let requested = overrides.action {
            let copies = requested == .copy
            let saves = requested == .save
            return ExportPolicy(copiesToClipboard: copies, savesToFolder: saves, staging: !saves)
        }
        let action = settings.defaultAction
        return ExportPolicy(
            copiesToClipboard: action.copiesToClipboard,
            savesToFolder: action.savesToFolder,
            staging: !action.savesToFolder
        )
    }

    private func encodingOptions(for capture: Capture) -> EncodingOptions {
        var format = settings.imageFormat
        // A transparent window capture written as JPEG would be silently composited onto
        // black; PNG keeps what the user was promised (docs/03 §1.2).
        let isTransparentWindow = {
            guard case .window = capture.metadata.source else { return false }
            return settings.transparentWindowBackground && !format.supportsTransparency
        }()
        if isTransparentWindow {
            logger.info("Falling back to PNG so the window's transparency survives")
            format = .png
        }
        // An HDR capture written as JPEG is quantised to eight bits and tone-mapped on
        // the way out, which throws away the reason it was captured in HDR (docs/06 M25).
        if capture.image.bitsPerComponent > 8, !format.supportsHighBitDepth {
            logger.info("Falling back to HEIC so the capture's dynamic range survives")
            format = .heic
        }
        return EncodingOptions(
            format: format,
            scale: capture.metadata.scale,
            downscaleToOneToOne: settings.downscaleRetinaCaptures
        )
    }

    private func context(for capture: Capture) -> FilenameContext {
        FilenameContext(
            applicationName: capture.metadata.frontmostApp?.name,
            width: capture.metadata.pixelSize.width,
            height: capture.metadata.pixelSize.height,
            date: capture.metadata.capturedAt
        )
    }

    // MARK: - Clipboard

    /// PNG rather than TIFF, because that is what other apps paste losslessly, and as
    /// data rather than an `NSImage` so no resampling can creep in.
    private func copyToClipboard(_ data: Data, format: ImageFormat) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let type: NSPasteboard.PasteboardType = switch format {
        case .png: .png
        case .jpeg, .heic, .webp: NSPasteboard.PasteboardType(format.contentType.identifier)
        }
        let wrote = pasteboard.setData(data, forType: type)
        if wrote {
            logger.info("Copied \(data.count, privacy: .public) bytes to the clipboard")
        }
        return wrote
    }
}
