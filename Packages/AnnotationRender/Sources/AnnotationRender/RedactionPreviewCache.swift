import AnnotationModel
import CoreGraphics
import Foundation
import os
import Shared

/// Bounded live redaction previews (docs/16 ED-15).
///
/// Re-blurring on every click rebuilt a Core Image graph for boxes that had not moved.
/// The cache keys on the pixel box, the style and the owning preview source, and drops
/// the oldest entries once the estimated byte budget is crossed.
///
/// Keyed by a per-source token rather than by `ObjectIdentifier(CGImage)`: an image's
/// address is reused as soon as it is freed, so a window closed and another opened could
/// be handed the first window's pixels. The token also lets a closing window take its
/// entries with it, which matters because the editor process can host several windows.
final class RedactionPreviewCache: @unchecked Sendable {
    static let shared = RedactionPreviewCache()

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let budget: Int

    init(budget: Int = 32 * 1024 * 1024) {
        self.budget = budget
    }

    private struct State {
        var order: [Key] = []
        var images: [Key: CGImage] = [:]
        var bytes = 0
    }

    struct Key: Hashable, Sendable {
        /// The `RedactionPreviewSource` the preview was made from.
        var token: UUID
        /// The region in base-image pixels — what the rasteriser actually crops.
        var pixelBox: CGRect
        var style: RedactionStyle

        init(token: UUID, spec: RedactionSpec, scale: CGFloat) {
            self.token = token
            pixelBox = RedactionRasterizer.pixelBox(of: spec.rect, scale: scale)
            style = spec.style
        }
    }

    func image(for key: Key) -> CGImage? {
        lock.withLock { $0.images[key] }
    }

    func insert(_ image: CGImage, for key: Key) {
        let budget = budget
        lock.withLock { state in
            if let replaced = state.images.updateValue(image, forKey: key) {
                state.bytes -= Self.cost(of: replaced)
                state.order.removeAll { $0 == key }
            }
            state.order.append(key)
            state.bytes += Self.cost(of: image)
            while state.bytes > budget, let oldest = state.order.first {
                state.order.removeFirst()
                if let evicted = state.images.removeValue(forKey: oldest) {
                    state.bytes -= Self.cost(of: evicted)
                }
            }
        }
    }

    /// Drops every preview a source made, when its window goes away.
    func removeAll(token: UUID) {
        lock.withLock { state in
            state.order.removeAll { $0.token == token }
            for key in state.images.keys where key.token == token {
                if let removed = state.images.removeValue(forKey: key) {
                    state.bytes -= Self.cost(of: removed)
                }
            }
        }
    }

    func removeAll() {
        lock.withLock { state in
            state.order.removeAll()
            state.images.removeAll()
            state.bytes = 0
        }
    }

    /// Entries and estimated bytes, for tests.
    var usage: (entries: Int, bytes: Int) {
        lock.withLock { ($0.images.count, $0.bytes) }
    }

    private static func cost(of image: CGImage) -> Int {
        image.width * image.height * 4
    }
}
