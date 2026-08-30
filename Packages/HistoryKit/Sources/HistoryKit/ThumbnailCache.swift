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
///
/// Two caches rather than one: the menu-bar strip and the History grid share a 6 MB
/// ceiling, but they must not evict each other. Grid churn from scrolling the library
/// would otherwise throw away the eight thumbnails the menu just decoded, and the strip
/// would decode them again every time the menu opened (docs/10 R2.4).
@MainActor
public final class ThumbnailCache {
    public enum Scope: Sendable {
        /// The last-8 strip in the status menu. Small, stable, purged when the menu closes.
        case strip
        /// The History window grid. Larger, purged when the window closes.
        case grid
    }

    private let strip = NSCache<NSString, CGImageBox>()
    private let grid = NSCache<NSString, CGImageBox>()
    private let loader = ThumbnailLoader()
    private let logger = KadrLog.logger(.history)
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    /// - Parameters:
    ///   - costLimit: approximate bytes to keep across both scopes, default 6 MB.
    ///   - stripCostLimit: the strip's own sub-budget, so grid churn cannot evict it.
    public init(costLimit: Int = 6 * 1024 * 1024, stripCostLimit: Int = 1536 * 1024) {
        strip.totalCostLimit = stripCostLimit
        grid.totalCostLimit = max(costLimit - stripCostLimit, stripCostLimit)
        startWatchingMemoryPressure()
    }

    /// Returns a cached thumbnail, loading it if this is the first ask.
    public func thumbnail(for url: URL, maxPixelSize: Int, scope: Scope = .grid) -> CGImage? {
        let key = "\(url.path)@\(maxPixelSize)" as NSString
        let cache = cache(for: scope)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }
        guard let image = loader.thumbnail(for: url, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(CGImageBox(image), forKey: key, cost: image.height * image.bytesPerRow)
        return image
    }

    public func purgeStrip() {
        strip.removeAllObjects()
    }

    public func removeAll() {
        strip.removeAllObjects()
        grid.removeAllObjects()
    }

    private func cache(for scope: Scope) -> NSCache<NSString, CGImageBox> {
        switch scope {
        case .strip: strip
        case .grid: grid
        }
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
