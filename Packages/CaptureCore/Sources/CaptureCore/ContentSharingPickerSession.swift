import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Shared

/// Capture with **no** Screen Recording permission at all (docs/04 §4.1).
///
/// `SCContentSharingPicker` is a system-owned picker: macOS shows it, the user chooses a
/// window or display, and the app receives a filter for that choice without ever holding
/// a TCC grant. That makes it the answer to "the app is useless until you restart it
/// after granting permission" — Kadr can capture on first launch, before onboarding.
///
/// The picked `SCContentFilter` never leaves this object, so nothing non-`Sendable`
/// crosses an isolation boundary: the session captures and hands back a `Capture`.
@MainActor
public final class ContentSharingPickerSession: NSObject {
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)
    private let picker = SCContentSharingPicker.shared
    // Boxed because `SCContentFilter` is not `Sendable` and a continuation's value must be.
    private var continuation: CheckedContinuation<UncheckedSendableBox<SCContentFilter>, any Error>?
    private var isObserving = false

    override public init() {
        super.init()
    }

    deinit {
        // The picker is a process-wide singleton; leaving a dead observer on it leaks.
        MainActor.assumeIsolated {
            if isObserving {
                picker.remove(self)
            }
        }
    }

    /// Whether the picker is available on this system.
    public static var isAvailable: Bool {
        true
    }

    /// Presents the system picker and captures whatever the user chooses.
    ///
    /// - Parameter style: which tab of the picker to open on — window, display or app.
    public func captureUserSelection(style: SCShareableContentStyle = .window) async throws -> Capture {
        let filter = try await pickFilter(style: style)

        let state = signposter.beginInterval("capturePickerSelection")
        defer { signposter.endInterval("capturePickerSelection", state) }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        let contentRect = DisplayRect(cgRect: filter.contentRect)

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return Capture(
                image: image,
                metadata: CaptureMetadata(
                    source: .picker,
                    displayID: nil,
                    scale: DisplayScale(scale),
                    pointRect: contentRect,
                    pixelSize: PixelSize(width: image.width, height: image.height),
                    colorSpaceName: image.colorSpace?.name as String?,
                    frontmostApp: nil
                )
            )
        } catch {
            throw CaptureError.mapping(error)
        }
    }

    /// Presents the picker and resolves with the user's choice.
    public func pickFilter(style: SCShareableContentStyle = .window) async throws -> SCContentFilter {
        if continuation != nil {
            throw CaptureError.captureFailed(code: -1, description: "A picker session is already open.")
        }

        startObserving()

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay, .singleApplication]
        // Kadr's own overlays are never a sensible thing to capture.
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap(\.self)
        picker.defaultConfiguration = configuration
        picker.isActive = true

        defer { picker.isActive = false }

        let boxed = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present(using: style)
        }
        return boxed.value
    }

    private func startObserving() {
        guard !isObserving else { return }
        picker.add(self)
        isObserving = true
    }

    private func finish(with result: Result<UncheckedSendableBox<SCContentFilter>, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension ContentSharingPickerSession: SCContentSharingPickerObserver {
    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let boxed = UncheckedSendableBox(filter)
        Task { @MainActor in
            self.finish(with: .success(boxed))
        }
    }

    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            self.finish(with: .failure(CancellationError()))
        }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let boxed = UncheckedSendableBox(error)
        Task { @MainActor in
            self.finish(with: .failure(CaptureError.mapping(boxed.value)))
        }
    }
}
