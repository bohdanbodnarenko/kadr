import AppKit
import CaptureCore
import os
import Shared

/// The permission-free capture path and the app that was in front at hotkey time.
@MainActor
extension AreaCaptureCoordinator {
    /// The frontmost app right now, as a value.
    static func currentFrontmostApp() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(name: app.localizedName, bundleIdentifier: app.bundleIdentifier)
    }

    /// Captures through `SCContentSharingPicker`, which needs no permission at all
    /// (docs/04 §4.1) — the way to stay useful before, or without, a TCC grant.
    func captureWithSystemPicker() {
        rememberBeautifySkip()
        let session = ContentSharingPickerSession()
        pickerSession = session
        inFlight = Task { [weak self] in
            guard let self else { return }
            defer { pickerSession = nil }
            do {
                let capture = try await session.captureUserSelection()
                await deliver(capture)
            } catch is CancellationError {
                logger.info("Picker capture cancelled")
            } catch {
                let mapped = CaptureError.mapping(error)
                logger.error("Picker capture failed: \(mapped.errorDescription ?? "unknown", privacy: .public)")
            }
        }
    }
}
