import AppKit
import CaptureCore
import os
import OverlayKit
import RecordingCore
import SelectionUI
import Shared

/// Picking what to record (docs/03 §1.8).
///
/// Its own file because choosing a target and running a recording are different jobs, and
/// because `RecordingTarget.window` existed for the whole life of the recorder with nothing
/// able to reach it: the app offered Region and Screen, so recording a single window — the
/// commonest thing anybody demonstrates — meant drawing a rectangle around it by hand and
/// hoping it did not move.
@MainActor
extension RecordingCoordinator {
    /// Lets the floating island pick a window without starting the take.
    func pickWindow(completion: @escaping (WindowSelection?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                await CaptureExclusionPush.into(captureEngine)
                let freezes = try await captureEngine.freezeAllDisplays()
                let windows = try await captureEngine.shareableContent().windows
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
                permissions.noteCaptureSuccess()
                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) },
                    mode: .window,
                    windows: windows
                ) { outcome in
                    if case let .window(selection) = outcome {
                        completion(selection)
                    } else {
                        completion(nil)
                    }
                }
            } catch {
                permissions.noteCaptureFailure(error)
                logger.error("Could not freeze to pick a window: \(error.localizedDescription, privacy: .public)")
                // A lapsed grant ended here silently: the picker simply never appeared
                // (docs/16 REC-20, docs/17 T-REC-9).
                presentPermissionRecoveryIfNeeded(error)
                completion(nil)
            }
        }
    }

    /// Records one window, picked with the same overlay stills use (docs/03 §1.8).
    ///
    /// Used by automation and GIF-style one-shots that should start as soon as a window
    /// is chosen. The floating island uses `pickWindow` so Record is a separate press.
    func beginWindowRecording() {
        guard !state.isActive else { return }
        pickWindow { [weak self] selection in
            guard let self, let selection else { return }
            beginWindowHighlight(from: selection)
            startAfterCountdown(target: .window(selection.window.id))
        }
    }
}
