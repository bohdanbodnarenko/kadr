import AVFoundation
import CoreGraphics
import Foundation
import os
import Shared

/// LRU filmstrip tiles keyed by `(level, index)` (docs/16 STU-B5).
///
/// Zooming the timeline used to re-decode every clip because the lane's task identity
/// included the pixel width. Tiles are requested only for the visible level, fall back to
/// a parent tile, and stay frozen while a pinch is in flight.
actor StudioThumbnailStore {
    struct Key: Hashable, Sendable {
        var path: String
        var level: Int
        var index: Int
    }

    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let cap = 256
    private let signposter = KadrLog.signposter(.app)

    static let shared = StudioThumbnailStore()

    func image(for key: Key) -> CGImage? {
        guard let image = images[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return image
    }

    func parent(of key: Key) -> CGImage? {
        guard key.level > 0 else { return nil }
        return image(for: Key(path: key.path, level: key.level - 1, index: key.index / 2))
    }

    func store(_ image: CGImage, for key: Key) {
        if images[key] == nil, images.count >= cap, let oldest = order.first {
            images[oldest] = nil
            order.removeFirst()
        }
        images[key] = image
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    func tile(
        url: URL,
        time: TimeInterval,
        level: Int,
        index: Int,
        size: CGSize
    ) async -> CGImage? {
        let key = Key(path: url.path, level: level, index: index)
        if let cached = image(for: key) {
            return cached
        }
        let state = signposter.beginInterval("studio.thumbnail.decode")
        defer { signposter.endInterval("studio.thumbnail.decode", state) }
        let decoded = await StudioFilmstrip.images(from: url, times: [time], maximumSize: size).first
        if let decoded {
            store(decoded, for: key)
            return decoded
        }
        return parent(of: key)
    }
}
