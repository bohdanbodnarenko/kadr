import AVFoundation
import Foundation
import MediaExport
import StudioRender
import StudioSession
import Testing
import UniformTypeIdentifiers
@testable import EditorUI

@Suite("Studio filmstrip")
struct StudioFilmstripTests {
    @Test("Sample times are midpoints of equal slices")
    func sampleTimesAreMidpoints() {
        let times = StudioFilmstrip.sampleTimes(start: 10, duration: 4, count: 4)
        #expect(times == [10.5, 11.5, 12.5, 13.5])
    }

    @Test("A single tile samples the middle of the clip")
    func oneTileIsTheMiddle() {
        #expect(StudioFilmstrip.sampleTimes(start: 0, duration: 2, count: 1) == [1])
    }

    @Test("Zero duration or zero count yields no times")
    func emptyInputs() {
        #expect(StudioFilmstrip.sampleTimes(start: 0, duration: 0, count: 4).isEmpty)
        #expect(StudioFilmstrip.sampleTimes(start: 0, duration: 2, count: 0).isEmpty)
    }

    @Test("A missing file yields no frames rather than throwing")
    func missingFile() async {
        let url = URL(fileURLWithPath: "/tmp/kadr-no-such-recording.mov")
        let images = await StudioFilmstrip.images(from: url, times: [0, 0.5, 1])
        #expect(images.isEmpty)
    }

    @Test("Tile count is at least one and grows with width")
    func tileCount() {
        #expect(StudioFilmstrip.tileCount(forWidth: 10) == 1)
        #expect(StudioFilmstrip.tileCount(forWidth: 108) == 3)
    }

    /// docs/18 STU-15: a long transcript is rows a lazy stack can skip, in order.
    @Test("Transcript tracks split into ordered rows of bounded size", arguments: [0, 1, 80, 81, 1000])
    func transcriptChunks(count: Int) {
        let words = (0 ..< count).map { TranscriptWord(text: "w\($0)", start: Double($0), end: Double($0) + 0.5) }
        let group = TranscriptTrackGroup(track: .mixed, words: words)
        #expect(group.chunks.flatMap(\.words) == words)
        #expect(group.chunks.allSatisfy { $0.words.count <= TranscriptTrackGroup.chunkSize })
    }

    /// docs/18 STU-15: a fully zoomed long recording does not lay out thousands of tiles.
    @Test("Tile count is capped for very wide lanes", arguments: [CGFloat(200_000), 5_000_000, .infinity])
    func tileCountCap(width: CGFloat) {
        #expect(StudioFilmstrip.tileCount(forWidth: width) <= StudioFilmstrip.maximumTiles)
    }
}

/// The filmstrip cache's recency list (docs/11 S2).
///
/// Scripted as operations and the order they should leave behind, because an LRU is only
/// wrong in the sequence of things that happened to it.
@Suite("Studio LRU cache")
struct StudioLRUCacheTests {
    enum Step: Sendable, CustomStringConvertible {
        case insert(String)
        case read(String)
        case remove(String)

        var description: String {
            switch self {
            case let .insert(key): "+\(key)"
            case let .read(key): "?\(key)"
            case let .remove(key): "-\(key)"
            }
        }
    }

    struct Script: Sendable {
        var capacity: Int
        var steps: [Step]
        var oldestFirst: [String]
    }

    static let scripts: [Script] = [
        Script(capacity: 2, steps: [], oldestFirst: []),
        Script(capacity: 2, steps: [.insert("a")], oldestFirst: ["a"]),
        Script(capacity: 2, steps: [.insert("a"), .insert("b")], oldestFirst: ["a", "b"]),
        Script(capacity: 2, steps: [.insert("a"), .insert("b"), .insert("c")], oldestFirst: ["b", "c"]),
        Script(capacity: 2, steps: [.insert("a"), .insert("b"), .read("a"), .insert("c")], oldestFirst: ["a", "c"]),
        Script(capacity: 2, steps: [.insert("a"), .insert("b"), .insert("a")], oldestFirst: ["b", "a"]),
        Script(
            capacity: 3,
            steps: [.insert("a"), .insert("b"), .insert("c"), .read("b")],
            oldestFirst: ["a", "c", "b"]
        ),
        Script(capacity: 3, steps: [.insert("a"), .insert("b"), .insert("c"), .remove("b")], oldestFirst: ["a", "c"]),
        Script(
            capacity: 3,
            steps: [.insert("a"), .insert("b"), .remove("a"), .insert("c"), .insert("d")],
            oldestFirst: ["b", "c", "d"]
        ),
        Script(capacity: 3, steps: [.insert("a"), .remove("a"), .insert("b")], oldestFirst: ["b"]),
        Script(capacity: 1, steps: [.insert("a"), .insert("b"), .read("a")], oldestFirst: ["b"]),
        Script(capacity: 0, steps: [.insert("a"), .insert("b")], oldestFirst: ["b"]),
        Script(capacity: 2, steps: [.insert("a"), .read("zz"), .remove("zz")], oldestFirst: ["a"])
    ]

    @Test("Operations leave keys in recency order", arguments: scripts)
    func recency(_ script: Script) {
        var cache = StudioLRUCache<String, Int>(capacity: script.capacity)
        var written = 0
        for step in script.steps {
            switch step {
            case let .insert(key):
                written += 1
                cache.insert(written, for: key)
            case let .read(key):
                _ = cache.value(for: key)
            case let .remove(key):
                cache.remove(key)
            }
        }
        #expect(cache.keysByRecency == script.oldestFirst)
        #expect(cache.count == script.oldestFirst.count)
        #expect(Set(cache.keys) == Set(script.oldestFirst))
    }

    @Test("A re-inserted key holds its new value")
    func reinsertReplaces() {
        var cache = StudioLRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "a")
        #expect(cache.peek("a") == 2)
        #expect(cache.count == 1)
    }

    @Test("Peeking does not refresh recency")
    func peekIsPassive() {
        var cache = StudioLRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.peek("a")
        cache.insert(3, for: "c")
        #expect(cache.keysByRecency == ["b", "c"])
    }

    @Test("Removing by predicate keeps the rest in order")
    func removeWhere() {
        var cache = StudioLRUCache<String, Int>(capacity: 8)
        for (index, key) in ["a1", "b1", "a2", "b2"].enumerated() {
            cache.insert(index, for: key)
        }
        cache.removeAll { $0.hasPrefix("a") }
        #expect(cache.keysByRecency == ["b1", "b2"])
    }

    /// A lookup and an eviction must not grow with the cache. Timed, loosely, against a
    /// cache far larger than the filmstrip's so a linear scan would show.
    @Test("Hits and evictions stay constant-time")
    func operationsAreConstantTime() {
        var cache = StudioLRUCache<Int, Int>(capacity: 50000)
        for key in 0 ..< 50000 {
            cache.insert(key, for: key)
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for key in 0 ..< 50000 {
                _ = cache.value(for: key)
                cache.insert(key, for: 50000 + key)
            }
        }
        #expect(cache.count == 50000)
        #expect(elapsed < .seconds(2), "100k operations took \(elapsed)")
    }
}

@Suite("Studio thumbnail store")
struct StudioThumbnailStoreTests {
    @Test("Tiles of different clips do not share a key")
    func clipsHaveTheirOwnTiles() {
        let first = StudioThumbnailStore.Key(path: "/a.mov", spanStart: 0, spanDuration: 4, level: 1, index: 0)
        let second = StudioThumbnailStore.Key(path: "/a.mov", spanStart: 4, spanDuration: 4, level: 1, index: 0)
        #expect(first != second)
        #expect(first.parent == StudioThumbnailStore.Key(
            path: "/a.mov",
            spanStart: 0,
            spanDuration: 4,
            level: 0,
            index: 0
        ))
        #expect(first.parent?.parent == nil)
    }

    @Test("A missing movie yields empty tiles, falling back to cached parents")
    func missingMovieFallsBack() async throws {
        let store = StudioThumbnailStore()
        let url = URL(fileURLWithPath: "/tmp/kadr-no-such-\(UUID().uuidString).mov")
        let parent = try #require(Self.pixel())
        await store.store(
            parent,
            for: .init(path: url.path, spanStart: 0, spanDuration: 2, level: 0, index: 0)
        )
        let tiles = await store.tiles(
            url: url,
            span: .init(start: 0, duration: 2, level: 1),
            requests: [.init(index: 0, time: 0.5), .init(index: 1, time: 1.5), .init(index: 2, time: 1.9)],
            size: CGSize(width: 80, height: 80)
        )
        #expect(tiles.count == 3)
        #expect(tiles[0] != nil && tiles[1] != nil, "the parent tile was not used")
        #expect(tiles[2] == nil)

        await store.purge(path: url.path)
        let purged = await store.image(for: .init(path: url.path, spanStart: 0, spanDuration: 2, level: 0, index: 0))
        #expect(purged == nil)
    }

    private static func pixel() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}

@Suite("Studio export settings")
struct StudioExportSettingsTests {
    @Test("1080p caps the long edge at 1920")
    func fullHDIsNineteenTwenty() {
        var settings = StudioExportSettings()
        settings.resolution = .fullHD
        #expect(settings.maxLongestEdge == 1920)
        #expect(settings.rendererOptions.maxLongestEdge == 1920)
    }

    @Test("MP4 is a different container than MOV")
    func mp4Container() {
        var settings = StudioExportSettings()
        settings.container = .mp4
        #expect(settings.filenameExtension == "mp4")
        #expect(settings.rendererOptions.fileType == .mp4)
        #expect(settings.utType == .mpeg4Movie)
    }

    @Test("Low quality lowers the bit-rate multiplier")
    func qualityScalesBitRate() {
        var settings = StudioExportSettings()
        settings.quality = .low
        #expect(settings.rendererOptions.bitRateMultiplier == 0.3)
        settings.quality = .high
        #expect(settings.rendererOptions.bitRateMultiplier == 1)
    }

    @Test("Audio can be left out of the encode")
    func droppingAudio() {
        var settings = StudioExportSettings()
        settings.includeAudio = false
        #expect(!settings.rendererOptions.includeAudio)
    }

    @Test("H.264 is the compatibility codec")
    func h264() {
        var settings = StudioExportSettings()
        settings.codec = .h264
        #expect(settings.rendererOptions.codec == .h264)
    }

    @Test("GIF is an animated image, not a movie")
    func gifContainer() {
        var settings = StudioExportSettings()
        settings.container = .gif
        settings.includeAudio = true
        settings.quality = .high
        #expect(settings.filenameExtension == "gif")
        #expect(settings.utType == .gif)
        #expect(!settings.rendererOptions.includeAudio)
        #expect(settings.rendererOptions.fileType == .mov)
        #expect(settings.rendererOptions.codec == .h264)
        #expect(settings.maxLongestEdge == 800)
        #expect(settings.gifOptions.frameRate == 15)
    }

    @Test("A smaller GIF uses the chosen width and rate")
    func gifResolutionCap() {
        var settings = StudioExportSettings()
        settings.container = .gif
        settings.gifWidth = .small
        settings.gifFrameRate = .light
        #expect(settings.gifOptions.maximumWidth == 480)
        #expect(settings.gifOptions.frameRate == 8)
    }

    @Test("Export fps is min of the choice and the recording")
    func frameRateIsCappedByTheManifest() {
        var settings = StudioExportSettings()
        settings.frameRate = .sixty
        #expect(settings.rendererOptions(manifestFrameRate: 30).frameRate == 30)
        settings.frameRate = .thirty
        #expect(settings.rendererOptions(manifestFrameRate: 60).frameRate == 30)
        settings.frameRate = .source
        #expect(settings.rendererOptions(manifestFrameRate: 24).frameRate == 24)
    }
}
