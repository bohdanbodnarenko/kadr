import AppKit
import CoreGraphics
import Shared

/// Corner handles for confirm-selection mode (docs/03 §1.1, docs/14 UX-17C).
///
/// Pure CALayer squares — no views, no hit testing here. The view decides which handle
/// a pointer event belongs to using the same geometry.
@MainActor
final class SelectionHandleLayerGroup {
    enum Corner: CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    let container = CALayer()
    private let handleLayers: [Corner: CALayer] = Dictionary(
        uniqueKeysWithValues: Corner.allCases.map { corner in
            let layer = CALayer()
            layer.backgroundColor = NSColor.white.cgColor
            layer.borderColor = NSColor.black.withAlphaComponent(0.65).cgColor
            layer.borderWidth = 1
            layer.cornerRadius = 2
            layer.isHidden = true
            return (corner, layer)
        }
    )

    private static let handleSize: CGFloat = 8
    private static let hitRadius: CGFloat = 10

    init() {
        for layer in handleLayers.values {
            container.addSublayer(layer)
        }
    }

    func show(along rect: CGRect, scale: DisplayScale) {
        let size = Self.handleSize / scale.factor
        let inset = size / 2
        for (corner, layer) in handleLayers {
            let center = corner.point(in: rect)
            layer.frame = CGRect(
                x: center.x - inset,
                y: center.y - inset,
                width: size,
                height: size
            )
            layer.isHidden = false
        }
        container.isHidden = false
    }

    func hide() {
        for layer in handleLayers.values {
            layer.isHidden = true
        }
        container.isHidden = true
    }

    func corner(at point: CGPoint, in rect: CGRect, scale: DisplayScale) -> Corner? {
        let radius = Self.hitRadius / scale.factor
        for corner in Corner.allCases where corner.point(in: rect).distance(to: point) <= radius {
            return corner
        }
        return nil
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
