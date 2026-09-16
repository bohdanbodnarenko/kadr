import AVFoundation
import CoreGraphics
import Foundation
import os
import Shared

/// LRU filmstrip tiles for the studio timeline (docs/16 STU-B5).
///
/// Zooming the timeline used to re-decode every clip because the lane's task identity
/// included the pixel width. Tiles are requested only for the visible level and fall back to
/// a parent tile.
///
/// Decoding is batched per lane (docs/11 S2). Each tile used to build its own `AVURLAsset`
/// and `AVAssetImageGenerator` — re-parsing the movie header per tile — and asked for one
/// frame at a time. Now one generator per movie and size is kept while the studio is open,
/// and a lane's missing tiles go to it as one `images(for:)` request, which lets
/// AVFoundation decode them in a single forward pass.
actor StudioThumbnailStore {
    struct Key: Hashable, Sendable {
        var path: String
        /// The clip's source span, in milliseconds. Part of the key because two clips at the
        /// same level have tiles with the same indices and different pictures.
        var spanStart: Int
        var spanDuration: Int
        var level: Int
        var index: Int

        init(path: String, spanStart: TimeInterval, spanDuration: TimeInterval, level: Int, index: Int) {
            self.path = path
            self.spanStart = Int((spanStart * 1000).rounded())
            self.spanDuration = Int((spanDuration * 1000).rounded())
            self.level = level
            self.index = index
        }

        var parent: Key? {
            guard level > 0 else { return nil }
            var parent = self
            parent.level -= 1
            parent.index /= 2
            return parent
        }
    }

    /// Which clip a lane shows, and at what level of detail.
    struct Span: Sendable {
        var start: TimeInterval
        var duration: TimeInterval
        var level: Int
    }

    /// One tile a lane wants: where it sits in the lane and which source instant it shows.
    struct Request: Sendable {
        var index: Int
        var time: TimeInterval
    }

    private struct GeneratorKey: Hashable, Sendable {
        var path: String
        var width: Int
        var height: Int
    }

    private var images = StudioLRUCache<Key, CGImage>(capacity: 256)
    private var generators = StudioLRUCache<GeneratorKey, ImageGeneratorBox>(capacity: 4)
    /// How many batches are using each generator, so a cancelled batch only cancels the
    /// generator's outstanding work when nobody else is waiting on it.
    private var activeBatches: [GeneratorKey: Int] = [:]
    private let signposter = KadrLog.signposter(.app)

    static let shared = StudioThumbnailStore()

    func image(for key: Key) -> CGImage? {
        images.value(for: key)
    }

    func parent(of key: Key) -> CGImage? {
        guard let parent = key.parent else { return nil }
        return image(for: parent)
    }

    func store(_ image: CGImage, for key: Key) {
        images.insert(image, for: key)
    }

    /// The tiles of one lane, in request order, decoding whichever are not cached.
    ///
    /// A tile that cannot be decoded falls back to its parent level's tile, and to nothing
    /// if that is missing too — the lane is still a clip without a picture in it.
    /// Cancellation stops the batch and returns what is known so far.
    func tiles(url: URL, span: Span, requests: [Request], size: CGSize) async -> [CGImage?] {
        let keys = requests.map {
            Key(
                path: url.path,
                spanStart: span.start,
                spanDuration: span.duration,
                level: span.level,
                index: $0.index
            )
        }
        var result = keys.map { images.value(for: $0) }
        let missing = result.indices.filter { result[$0] == nil }
        guard !missing.isEmpty, !Task.isCancelled else {
            return fillingFromParents(result, keys: keys)
        }

        guard let found = generator(for: url, size: size) else {
            return fillingFromParents(result, keys: keys)
        }
        let generatorKey = found.key
        activeBatches[generatorKey, default: 0] += 1
        defer {
            activeBatches[generatorKey, default: 1] -= 1
            if activeBatches[generatorKey] == 0 {
                activeBatches[generatorKey] = nil
            }
        }

        let state = signposter.beginInterval("studio.thumbnail.batch", "\(missing.count) tiles")
        defer { signposter.endInterval("studio.thumbnail.batch", state) }

        let times = missing.map { requests[$0].time }
        let decodeState = signposter.beginInterval("studio.thumbnail.decode")
        defer { signposter.endInterval("studio.thumbnail.decode", decodeState) }
        let decoded = await withTaskCancellationHandler {
            await Self.decode(times, with: found.box)
        } onCancel: {
            Task { await self.cancelIfUnshared(generatorKey) }
        }
        for (offset, image) in decoded.enumerated() {
            guard let image else { continue }
            let slot = missing[offset]
            images.insert(image, for: keys[slot])
            result[slot] = image
        }
        return fillingFromParents(result, keys: keys)
    }

    /// Forgets a movie's decoders and tiles, for when its studio closes.
    func purge(path: String) {
        images.removeAll { $0.path == path }
        for key in generators.keys where key.path == path {
            generators.peek(key)?.generator.cancelAllCGImageGeneration()
            generators.remove(key)
        }
    }

    private func fillingFromParents(_ tiles: [CGImage?], keys: [Key]) -> [CGImage?] {
        zip(tiles, keys).map { tile, key in tile ?? parent(of: key) }
    }

    private func cancelIfUnshared(_ key: GeneratorKey) {
        guard activeBatches[key] == 1 else { return }
        generators.peek(key)?.generator.cancelAllCGImageGeneration()
    }

    private func generator(for url: URL, size: CGSize) -> (key: GeneratorKey, box: ImageGeneratorBox)? {
        let key = GeneratorKey(path: url.path, width: Int(size.width), height: Int(size.height))
        if let existing = generators.value(for: key) {
            return (key, existing)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let box = ImageGeneratorBox(generator: StudioFilmstrip.makeGenerator(for: url, maximumSize: size))
        generators.insert(box, for: key)
        return (key, box)
    }

    /// Runs one batch outside the actor, so the actor is free while frames decode.
    private nonisolated static func decode(_ times: [TimeInterval], with box: ImageGeneratorBox) async -> [CGImage?] {
        await StudioFilmstrip.images(from: box.generator, times: times)
    }
}

/// An image generator shared between batches.
///
/// `@unchecked Sendable` because `AVAssetImageGenerator` is not annotated, though the parts
/// used here are safe to share: its configuration is set once, before the box exists, and
/// the only calls made afterwards are `images(for:)` and `cancelAllCGImageGeneration()`,
/// which AVFoundation serialises internally.
final class ImageGeneratorBox: @unchecked Sendable {
    let generator: AVAssetImageGenerator

    init(generator: AVAssetImageGenerator) {
        self.generator = generator
    }
}

/// A fixed-capacity least-recently-used cache with O(1) lookups, inserts and evictions.
///
/// A dictionary of nodes threaded into a doubly linked list by key. The store used to keep
/// recency as an array and call `firstIndex(of:)` on every hit, which is linear in the
/// cache and ran once per tile per render.
struct StudioLRUCache<Key: Hashable, Value> {
    private struct Node {
        var value: Value
        var older: Key?
        var newer: Key?
    }

    let capacity: Int
    private var nodes: [Key: Node] = [:]
    private var oldest: Key?
    private var newest: Key?

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var count: Int {
        nodes.count
    }

    var keys: [Key] {
        Array(nodes.keys)
    }

    /// Keys from least to most recently used.
    var keysByRecency: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(nodes.count)
        var cursor = oldest
        while let key = cursor {
            keys.append(key)
            cursor = nodes[key]?.newer
        }
        return keys
    }

    /// The value for `key`, marking it most recently used.
    mutating func value(for key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToNewest(key)
        return node.value
    }

    /// The value for `key` without touching its recency.
    func peek(_ key: Key) -> Value? {
        nodes[key]?.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        if nodes[key] != nil {
            remove(key)
        } else if nodes.count >= capacity, let evicted = oldest {
            remove(evicted)
        }
        appendNewest(value, for: key)
    }

    mutating func remove(_ key: Key) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        if let older = node.older {
            nodes[older]?.newer = node.newer
        } else {
            oldest = node.newer
        }
        if let newer = node.newer {
            nodes[newer]?.older = node.older
        } else {
            newest = node.older
        }
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in nodes.keys where shouldRemove(key) {
            remove(key)
        }
    }

    private mutating func moveToNewest(_ key: Key) {
        guard newest != key, let value = nodes[key]?.value else { return }
        remove(key)
        appendNewest(value, for: key)
    }

    private mutating func appendNewest(_ value: Value, for key: Key) {
        nodes[key] = Node(value: value, older: newest, newer: nil)
        if let newest {
            nodes[newest]?.newer = key
        }
        newest = key
        if oldest == nil {
            oldest = key
        }
    }
}
