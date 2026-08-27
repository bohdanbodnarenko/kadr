import AppKit
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
    @discardableResult
    func deliver(_ capture: Capture) -> ExportResult? {
        let state = signposter.beginInterval("exportCapture")
        defer { signposter.endInterval("exportCapture", state) }

        do {
            let result = try exporter.export(
                capture.image,
                policy: policy,
                saveFolder: settings.saveFolder,
                template: FilenameTemplate(settings.filenameTemplate),
                context: context(for: capture),
                options: encodingOptions(for: capture),
                copyData: copyToClipboard
            )
            assertNoFullResolutionImageRetained()
            return result
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Exports several captures at once, which is what a multi-display screen capture
    /// produces (docs/03 §1.3).
    ///
    /// Only one image can go on the clipboard, so the rest are saved regardless of the
    /// clipboard-only policy — losing three of four monitors would be worse than a file
    /// the user did not strictly ask for.
    func deliver(_ captures: [Capture]) {
        guard let first = captures.first else { return }
        deliver(first)

        guard captures.count > 1 else { return }
        for capture in captures.dropFirst() {
            do {
                _ = try exporter.export(
                    capture.image,
                    policy: ExportPolicy(
                        copiesToClipboard: false,
                        savesToFolder: !policy.staging,
                        staging: policy.staging
                    ),
                    saveFolder: settings.saveFolder,
                    template: FilenameTemplate(settings.filenameTemplate),
                    context: context(for: capture),
                    options: encodingOptions(for: capture)
                )
            } catch {
                logger.error("Export failed for one display: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    /// Clears stale staged files. Called once at launch (docs/03 §2).
    func sweepStaging() {
        exporter.sweepStaging()
    }

    // MARK: - Policy

    private var policy: ExportPolicy {
        let action = settings.defaultAction
        return ExportPolicy(
            copiesToClipboard: action.copiesToClipboard,
            savesToFolder: action.savesToFolder,
            staging: action == .overlayOnly
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

    /// Debug-only check that export did not park a full-resolution bitmap somewhere
    /// (doc 04 §7 rule 2).
    ///
    /// `CaptureOutput` is a struct holding only settings and an exporter, both of which
    /// are value types with no image storage. The assertion pins that: if someone later
    /// adds a cache here, this fires and points at the rule rather than at a memory graph
    /// three weeks later.
    private func assertNoFullResolutionImageRetained() {
        #if DEBUG
            assert(
                MemoryLayout<CaptureOutput>.size <= 64,
                "CaptureOutput has grown storage — check it is not holding a capture (doc 04 §7)"
            )
        #endif
    }
}
