import CoreGraphics
import Dispatch
import Foundation
import os
import Shared

/// Caches thumbnails, and gives them back when the system asks (doc 04 §7 rule 5).
///
/// `NSCache` already evicts under pressure, but only for its own accounting. The explicit
/// memory-pressure source is what makes the agent a good citizen: when macOS is short of
/// memory, Kadr drops every thumbnail immediately rather than waiting to be killed.
@MainActor
public final class ThumbnailCache {
    private let cache = NSCache<NSString, CGImageBox>()
    private let loader = ThumbnailLoader()
    private let logger = KadrLog.logger(.history)
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    /// - Parameter costLimit: approximate bytes to keep, default 16 MB — dozens of cards
    ///   at 400 pt, and still a rounding error against the 30 MB idle budget.
    public init(costLimit: Int = 16 * 1024 * 1024) {
        cache.totalCostLimit = costLimit
        startWatchingMemoryPressure()
    }

    /// Returns a cached thumbnail, loading it if this is the first ask.
    public func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        let key = "\(url.path)@\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }
        guard let image = loader.thumbnail(for: url, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(CGImageBox(image), forKey: key, cost: image.height * image.bytesPerRow)
        return image
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    private func startWatchingMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.logger.info("Memory pressure — dropping cached thumbnails")
                self?.removeAll()
            }
        }
        source.resume()
        pressureSource = source
    }
}

/// `NSCache` needs a class; `CGImage` is one but not an `NSObject` subclass.
private final class CGImageBox {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
