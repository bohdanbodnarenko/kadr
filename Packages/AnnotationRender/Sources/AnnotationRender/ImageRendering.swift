import AnnotationModel
import CoreGraphics
import Foundation
import QuartzCore

/// Drawing an inserted image, for the layer tree and the export (docs/06 M24).
///
/// The PNG is decoded on demand and cached by the data's own identity: a composition with
/// four inserts redraws on every mouse-move while one of them is dragged, and decoding
/// four PNGs per frame is exactly the kind of thing that turns a 60 fps canvas into a
/// slideshow (docs/03 §3 accept list).
enum ImageRendering {
    /// Decoded images, keyed by the PNG's hash.
    ///
    /// Bounded, because a long editing session that swaps images repeatedly must not grow
    /// without limit. `NSCache` is the wrong tool here — this is a value cache with no
    /// object lifetime to hang off.
    private static let cache = ImageCache()

    static func decode(_ data: Data) -> CGImage? {
        cache.image(for: data)
    }

    /// The path an image's rounded corners clip to.
    static func clipPath(_ spec: ImageSpec) -> CGPath {
        CGPath(
            roundedRect: spec.rect.standardized,
            cornerWidth: spec.cornerRadius,
            cornerHeight: spec.cornerRadius,
            transform: nil
        )
    }

    /// A soft drop shadow, sized off the image rather than fixed, so a small insert does
    /// not look like it is floating a metre above the page.
    static func shadowRadius(_ spec: ImageSpec) -> CGFloat {
        max(4, min(spec.rect.width, spec.rect.height) * 0.04)
    }
}

/// A tiny bounded cache of decoded PNGs.
private final class ImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: CGImage] = [:]
    private var order: [Int] = []
    private let limit = 16

    func image(for data: Data) -> CGImage? {
        let key = data.hashValue
        lock.lock()
        defer { lock.unlock() }

        if let cached = entries[key] {
            return cached
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  pngDataProviderSource: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            return nil
        }

        entries[key] = image
        order.append(key)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
        return image
    }
}

extension AnnotationLayerFactory {
    /// The editing-time layer for an inserted image.
    static func imageLayer(_ spec: ImageSpec) -> CALayer? {
        guard let image = ImageRendering.decode(spec.pngData) else { return nil }
        let layer = CALayer()
        layer.frame = spec.rect.standardized
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = spec.cornerRadius > 0
        layer.cornerRadius = spec.cornerRadius
        layer.opacity = Float(spec.opacity)
        if spec.hasShadow {
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            layer.shadowOpacity = 0.35
            layer.shadowRadius = ImageRendering.shadowRadius(spec)
            layer.shadowOffset = CGSize(width: 0, height: ImageRendering.shadowRadius(spec) / 2)
            // A shadow needs to escape the layer's bounds, so rounded corners are clipped
            // by a mask instead of by `masksToBounds`.
            layer.masksToBounds = false
            if spec.cornerRadius > 0 {
                let mask = CAShapeLayer()
                mask.path = CGPath(
                    roundedRect: CGRect(origin: .zero, size: spec.rect.standardized.size),
                    cornerWidth: spec.cornerRadius,
                    cornerHeight: spec.cornerRadius,
                    transform: nil
                )
                layer.mask = mask
            }
        }
        return layer
    }

    static func updateImageLayer(_ layer: CALayer, spec: ImageSpec) {
        layer.frame = spec.rect.standardized
        layer.opacity = Float(spec.opacity)
        layer.cornerRadius = spec.cornerRadius
        if let mask = layer.mask as? CAShapeLayer {
            mask.path = CGPath(
                roundedRect: CGRect(origin: .zero, size: spec.rect.standardized.size),
                cornerWidth: spec.cornerRadius,
                cornerHeight: spec.cornerRadius,
                transform: nil
            )
        }
    }
}
