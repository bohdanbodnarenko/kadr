import AnnotationModel
import CoreGraphics
import Foundation
import os
import Shared

/// Bounded live redaction previews (docs/16 ED-15).
///
/// Re-blurring on every click rebuilt a Core Image graph for boxes that had not moved.
/// The cache keys on the integral pixel rect, the style and the image identity, and
/// drops the oldest entries once the estimated byte budget is crossed.
final class RedactionPreviewCache: @unchecked Sendable {
    static let shared = RedactionPreviewCache()

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let budget = 32 * 1024 * 1024

    private struct State {
        var order: [Key] = []
        var images: [Key: CGImage] = [:]
        var bytes = 0
    }

    struct Key: Hashable, Sendable {
        var imageIdentifier: ObjectIdentifier
        var rect: CGRect
        var style: RedactionStyle
    }

    func image(for spec: RedactionSpec, base: CGImage, scale: CGFloat, make: () -> CGImage?) -> CGImage? {
        let key = Key(
            imageIdentifier: ObjectIdentifier(base),
            rect: spec.rect.integral,
            style: spec.style
        )
        if let cached = lock.withLock({ $0.images[key] }) {
            return cached
        }
        guard let image = make() else { return nil }
        lock.withLock { state in
            let cost = image.width * image.height * 4
            state.images[key] = image
            state.order.append(key)
            state.bytes += cost
            while state.bytes > budget, let oldest = state.order.first {
                state.order.removeFirst()
                if let evicted = state.images.removeValue(forKey: oldest) {
                    state.bytes -= evicted.width * evicted.height * 4
                }
            }
        }
        return image
    }

    func removeAll() {
        lock.withLock { state in
            state.order.removeAll()
            state.images.removeAll()
            state.bytes = 0
        }
    }
}
