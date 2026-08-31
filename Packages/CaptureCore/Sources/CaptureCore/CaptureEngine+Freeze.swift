import AppKit
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Shared

/// Freezing the screen for the selection overlay (docs/03 §1.1).
///
/// Split from the engine on file length, and it reads as its own thing: a freeze is one
/// picture of every display taken as fast as ScreenCaptureKit can manage, so the overlay can
/// show the user exactly what was on screen at the moment they pressed the key — while a
/// capture is about producing a file somebody keeps.
public extension CaptureEngine {
    // MARK: - Freeze

    /// Captures every display at once, for the selection overlay to draw and crop from.
    ///
    /// The displays are captured concurrently in a task group because the budget is one
    /// freeze for *all* displays under 80 ms (docs/04 §4.2) — doing them in sequence
    /// spends that budget twice on a two-display desk.
    func freezeAllDisplays(options: FreezeOptions = FreezeOptions()) async throws -> [DisplayFreeze] {
        let state = signposter.beginInterval("freezeAllDisplays")
        defer { signposter.endInterval("freezeAllDisplays", state) }

        // macOS 15.2+: capture the display rects directly. Asking for shareable
        // content is what re-presents the screen-recording sheet on every freeze.
        if prefersDirectRectCapture {
            return try await freezeAllDisplaysDirectly(options: options)
        }

        let content = try await content(onScreenWindowsOnly: true)
        let excluded = options.excludesOwnWindows
            ? Self.windows(matching: excludedWindowIDs, in: content)
            : []
        // Read once, off the actor, so the concurrent freezes agree with each other and
        // with the capture that is cropped out of them (docs/04 §4.2).
        let range = dynamicRange

        return try await withThrowingTaskGroup(of: DisplayFreeze.self) { group in
            for display in content.displays {
                let boxed = UncheckedSendableBox((display: display, excluded: excluded))
                group.addTask {
                    try await self.freeze(
                        display: boxed.value.display,
                        excluding: boxed.value.excluded,
                        options: options,
                        dynamicRange: range
                    )
                }
            }
            var freezes: [DisplayFreeze] = []
            freezes.reserveCapacity(content.displays.count)
            for try await freeze in group {
                freezes.append(freeze)
            }
            // Task groups finish out of order; keep displays in a stable order.
            return freezes.sorted { $0.geometry.displayID < $1.geometry.displayID }
        }
    }
}
