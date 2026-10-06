import QuartzCore

/// The capture under the annotations, split into strips when it is very tall or wide
/// (docs/18 ED-13).
///
/// One layer holding a 30,000 px scrolling capture asks Core Animation for a texture
/// larger than the GPU allows, which either fails to draw or is uploaded in full on every
/// commit. Above `tileThreshold` the image is cut into strips of at most `tileLength`
/// pixels along its long side. `CGImage.cropping(to:)` shares the original's backing, so
/// the strips cost no extra memory.
final class BaseImageLayer: CALayer {
    /// The longest side, in pixels, drawn as a single layer.
    static let tileThreshold = 8192
    /// The longest side of one strip, in pixels.
    static let tileLength = 4096

    var image: CGImage? {
        didSet { rebuild() }
    }

    /// The strips, when the image is tiled. Empty for an ordinary capture.
    private(set) var tiles: [CALayer] = []
    private var tileRects: [CGRect] = []

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The pixel rects the strips cover, top-down along the image's long side. Empty when
    /// the image is small enough for one layer.
    static func tileRects(width: Int, height: Int) -> [CGRect] {
        guard max(width, height) > tileThreshold else { return [] }
        let vertical = height >= width
        let length = vertical ? height : width
        return stride(from: 0, to: length, by: tileLength).map { start in
            let span = min(tileLength, length - start)
            return vertical
                ? CGRect(x: 0, y: start, width: width, height: span)
                : CGRect(x: start, y: 0, width: span, height: height)
        }
    }

    private func rebuild() {
        tiles.forEach { $0.removeFromSuperlayer() }
        tiles = []
        guard let image else {
            contents = nil
            tileRects = []
            return
        }
        tileRects = Self.tileRects(width: image.width, height: image.height)
        guard !tileRects.isEmpty else {
            contents = image
            return
        }
        contents = nil
        for rect in tileRects {
            let tile = CALayer()
            tile.contents = image.cropping(to: rect)
            tile.magnificationFilter = magnificationFilter
            tile.minificationFilter = minificationFilter
            // Strips move with the base; animating them separately would tear the image.
            tile.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
            addSublayer(tile)
            tiles.append(tile)
        }
        setNeedsLayout()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        guard let image, !tiles.isEmpty else { return }
        let scaleX = bounds.width / CGFloat(image.width)
        let scaleY = bounds.height / CGFloat(image.height)
        // Pixel rects run top-down; so does the canvas when its geometry is flipped.
        let topDown = contentsAreFlipped()
        for (tile, rect) in zip(tiles, tileRects) {
            let y = topDown ? rect.minY * scaleY : (CGFloat(image.height) - rect.maxY) * scaleY
            tile.frame = CGRect(
                x: rect.minX * scaleX,
                y: y,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )
        }
    }
}
