import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import os
import Shared

/// Decoded wallpapers, kept at bucketed sizes (docs/09 U1.1).
///
/// A wallpaper backdrop is decoded on every render — every inspector slider tick, every
/// preview, every export. A 6K desktop picture is around 100 MB decoded, so doing that
/// per frame is what makes a beautify panel feel broken.
///
/// Two things fix it. `CGImageSourceCreateThumbnailAtIndex` decodes *directly* at the size
/// wanted rather than decoding full-size and scaling, so the 100 MB never exists. And the
/// requested size is rounded up to a bucket, so dragging a padding slider — which changes
/// the canvas by a pixel or two per frame — asks for the same bucket every time and hits
/// the cache instead of decoding again.
///
/// The cache is bounded by bytes rather than count: one entry can be 50 MB, and a count
/// limit would let a handful of them own most of the editor's memory (docs/04 §7).
public final class WallpaperCache: @unchecked Sendable {
    /// Shared because the editor renders the same wallpaper from several places at once —
    /// live canvas, preview thumbnail, export — and they should not each hold a copy.
    public static let shared = WallpaperCache()

    private let cache = NSCache<NSString, CacheEntry>()
    private let logger = KadrLog.logger(.overlay)
    private let lock = NSLock()
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    /// Doubling buckets from 256 px up, capped at 4096. A 8192 bucket is one 4096-class
    /// wallpaper decoded at 67 MB — more than the whole cache is allowed to hold
    /// (docs/10 R2.4).
    public static let buckets: [Int] = [256, 512, 1024, 2048, 4096]

    /// Roughly the budget docs/10 R2.4 leaves the editor for decorative pixels.
    private static let byteLimit = 48 * 1024 * 1024

    private final class CacheEntry {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    public init() {
        cache.totalCostLimit = Self.byteLimit
        startWatchingMemoryPressure()
    }

    /// The bucket a request of `longestEdge` pixels rounds up into.
    public static func bucket(for longestEdge: CGFloat) -> Int {
        let wanted = Int(longestEdge.rounded(.up))
        return buckets.first { $0 >= wanted } ?? buckets[buckets.count - 1]
    }

    /// A wallpaper decoded at least as large as `longestEdge`, or nil if it cannot be read.
    public func image(at path: String, longestEdge: CGFloat) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let bucket = Self.bucket(for: longestEdge)
        let key = "\(path)@\(bucket)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            logger.error("Could not open a wallpaper for beautify")
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            logger.error("Could not decode a wallpaper for beautify")
            return nil
        }

        cache.setObject(CacheEntry(image: image), forKey: key, cost: image.height * image.bytesPerRow)
        return image
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
    }

    private func startWatchingMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.logger.info("Memory pressure — dropping cached wallpapers")
            self?.removeAll()
        }
        source.resume()
        pressureSource = source
    }
}
