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

    /// An area capture is cropped out of the freeze, so "Include the pointer" has to reach
    /// it here or it never reaches the file (docs/17 T-CAP-12). Not for Capture Text or the
    /// eyedropper: the pointer would be read as text, or sampled as the colour.
    func freezeOptions(for purpose: SelectionPurpose) -> FreezeOptions {
        FreezeOptions(includesCursor: Self.freezeIncludesCursor(
            setting: includesCursor,
            purpose: purpose,
            eyedropper: startsInEyedropperMode
        ))
    }

    /// Whether the pointer belongs in the freeze an overlay crops from.
    nonisolated static func freezeIncludesCursor(
        setting: Bool,
        purpose: SelectionPurpose,
        eyedropper: Bool
    ) -> Bool {
        setting && (purpose == .capture || purpose == .inspect) && !eyedropper
    }
}
