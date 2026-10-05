import CaptureCore
import SelectionUI

extension AreaCaptureCoordinator {
    /// The windows the overlay can pick, front to back.
    nonisolated static func pickableWindows(
        from engine: CaptureEngine
    ) async throws -> [PickableWindowDescriptor] {
        try await engine.shareableContent().windows
            .filter(\.isPickableWindow)
            .map {
                PickableWindowDescriptor(
                    id: $0.id,
                    title: $0.title,
                    applicationName: $0.applicationName,
                    bundleIdentifier: $0.bundleIdentifier,
                    layer: $0.layer,
                    globalFrame: $0.frame
                )
            }
    }
}
