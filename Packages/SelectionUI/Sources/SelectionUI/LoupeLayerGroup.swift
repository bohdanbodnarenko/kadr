import AppKit
import Shared

/// The magnifier loupe's layers and the logic that positions them (docs/03 §1.1).
///
/// Split out of `SelectionOverlayView` because the loupe is a self-contained widget:
/// a magnified crop of the frozen image, a one-line-per-pixel grid, a highlight on the
/// pixel under the pointer, and a coordinate/colour readout.
@MainActor
final class LoupeLayerGroup {
    /// 8× zoom over a 144 pt loupe, so it shows 18 points of screen (docs/03 §1.1).
    private static let zoom: CGFloat = 8
    private static let side: CGFloat = 144
    private static let readoutHeight: CGFloat = 20
    private static let pointerOffset = CGSize(width: 24, height: 24)
    /// Below this the grid is denser than it is useful and just greys the loupe out.
    private static let minimumGridStep: CGFloat = 4

    let container = CALayer()
    private let imageLayer = CALayer()
    private let gridLayer = CAShapeLayer()
    private let centreLayer = CAShapeLayer()
    private let readoutBackground = CALayer()
    private let readoutLayer = CATextLayer()

    private let sampler: LoupeSampler

    init(sampler: LoupeSampler, scale: DisplayScale) {
        self.sampler = sampler

        container.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side + Self.readoutHeight)
        container.isHidden = true

        imageLayer.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        // Nearest-neighbour is the whole point: the loupe shows pixels, not a blur.
        imageLayer.magnificationFilter = .nearest
        imageLayer.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        imageLayer.borderWidth = 1
        imageLayer.cornerRadius = 6
        imageLayer.masksToBounds = true
        container.addSublayer(imageLayer)

        gridLayer.frame = imageLayer.bounds
        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.15).cgColor
        gridLayer.lineWidth = 1
        gridLayer.fillColor = nil
        imageLayer.addSublayer(gridLayer)

        centreLayer.frame = imageLayer.bounds
        centreLayer.strokeColor = NSColor.systemBlue.cgColor
        centreLayer.lineWidth = 1
        centreLayer.fillColor = nil
        imageLayer.addSublayer(centreLayer)

        readoutBackground.frame = CGRect(x: 0, y: Self.side, width: Self.side, height: Self.readoutHeight)
        readoutBackground.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        readoutBackground.cornerRadius = 4
        container.addSublayer(readoutBackground)

        readoutLayer.frame = readoutBackground.frame
        readoutLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        readoutLayer.fontSize = 10
        readoutLayer.foregroundColor = NSColor.white.cgColor
        readoutLayer.alignmentMode = .center
        readoutLayer.contentsScale = scale.factor
        container.addSublayer(readoutLayer)
    }

    func hide() {
        container.isHidden = true
    }

    /// Moves the loupe to the pointer and refreshes what it shows.
    ///
    /// Called on every mouse-moved event, so it does no allocation beyond the crop and
    /// runs inside the caller's disabled-action transaction.
    func update(pointer: CGPoint, within bounds: CGRect) {
        let sourceSide = Self.side / Self.zoom
        guard let region = sampler.magnifiedRegion(around: pointer, sideInPoints: sourceSide) else {
            hide()
            return
        }

        imageLayer.contents = region.image
        container.isHidden = false

        let colour = sampler.color(at: pointer)
        readoutLayer.string = [
            DimensionFormatter.pointerText(at: pointer),
            colour?.hexText
        ].compactMap(\.self).joined(separator: "  ")

        updateGrid(pixelsAcross: region.rect.width)
        position(near: pointer, within: bounds)
    }

    /// One grid line per captured pixel, so the loupe reads as pixels rather than a
    /// smeared zoom, plus a highlight on the pixel under the pointer.
    private func updateGrid(pixelsAcross: Int) {
        let step = Self.side / CGFloat(max(1, pixelsAcross))
        guard step >= Self.minimumGridStep else {
            gridLayer.path = nil
            centreLayer.path = nil
            return
        }

        let path = CGMutablePath()
        var offset: CGFloat = 0
        while offset <= Self.side {
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset, y: Self.side))
            path.move(to: CGPoint(x: 0, y: offset))
            path.addLine(to: CGPoint(x: Self.side, y: offset))
            offset += step
        }
        gridLayer.path = path

        let centre = (CGFloat(pixelsAcross) / 2).rounded(.down) * step
        centreLayer.path = CGPath(
            rect: CGRect(x: centre, y: centre, width: step, height: step),
            transform: nil
        )
    }

    /// Follows the pointer, flipping to its other side rather than running off screen.
    private func position(near pointer: CGPoint, within bounds: CGRect) {
        let size = container.bounds.size
        var origin = CGPoint(
            x: pointer.x + Self.pointerOffset.width,
            y: pointer.y + Self.pointerOffset.height
        )
        if origin.x + size.width > bounds.maxX {
            origin.x = pointer.x - Self.pointerOffset.width - size.width
        }
        if origin.y + size.height > bounds.maxY {
            origin.y = pointer.y - Self.pointerOffset.height - size.height
        }
        container.frame = CGRect(origin: origin, size: size)
    }
}
