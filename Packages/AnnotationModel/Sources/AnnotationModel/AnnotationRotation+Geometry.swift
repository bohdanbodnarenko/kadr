import CoreGraphics
import Foundation

public extension AnnotationRotation {
    /// `point` turned by `radians` about `center` — the inverse of `inverse(_:around:radians:)`.
    static func rotate(_ point: CGPoint, around center: CGPoint, radians: CGFloat) -> CGPoint {
        inverse(point, around: center, radians: -radians)
    }

    /// The same turn as an affine transform, for paths and graphics contexts.
    static func transform(radians: CGFloat, around center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
    }

    /// `rect` turned about its own centre, as a path.
    static func path(of rect: CGRect, radians: CGFloat) -> CGPath {
        guard radians != 0 else { return CGPath(rect: rect, transform: nil) }
        var transform = transform(radians: radians, around: CGPoint(x: rect.midX, y: rect.midY))
        return CGPath(rect: rect, transform: &transform)
    }
}

/// A lone rotated annotation's selection, in its own axes (docs/16 ED-10).
///
/// A rotated shape selected with an axis-aligned frame has its handles in empty space
/// beside its corners, and dragging one resizes a box the shape is not. So a single rotated
/// annotation gets an outline and handles turned with it, and a resize that happens in its
/// own axes.
public struct OrientedSelection: Equatable, Sendable {
    /// The annotation's extent before rotation.
    public let box: CGRect
    public let radians: CGFloat

    public var center: CGPoint {
        CGPoint(x: box.midX, y: box.midY)
    }

    /// Nil for anything that keeps the axis-aligned frame: several annotations, an
    /// unrotated one, and the ones with path handles or no resize at all.
    public init?(_ commands: [AnnotationCommand]) {
        guard commands.count == 1, let command = commands.first, command.canRotate,
              command.rotation != 0,
              !SelectionResizer.usesPathHandles(commands),
              !SelectionResizer.isMoveOnly(commands)
        else { return nil }
        let box = AnnotationHitTesting.unrotatedBounds(of: command)
        guard box.width > 0, box.height > 0 else { return nil }
        self.box = box
        radians = command.rotation
    }

    /// A local point (in `box`'s axes) where it appears on the canvas.
    public func world(_ local: CGPoint) -> CGPoint {
        AnnotationRotation.rotate(local, around: center, radians: radians)
    }

    /// A canvas point in `box`'s axes.
    public func local(_ world: CGPoint) -> CGPoint {
        AnnotationRotation.inverse(world, around: center, radians: radians)
    }

    /// The dashed outline, turned with the annotation.
    public func outline(padding: CGFloat) -> CGPath {
        AnnotationRotation.path(of: box.insetBy(dx: -padding, dy: -padding), radians: radians)
    }

    /// Resizes by one handle drag.
    ///
    /// The drag is read in the annotation's axes, the geometry is scaled there, and the
    /// result is shifted so the side or corner opposite the handle stays exactly where it
    /// was on the canvas — without that, the new box's new centre would swing the whole
    /// shape as it grew.
    /// One handle drag, in canvas points.
    public struct Drag: Equatable, Sendable {
        public var handle: CropHandle
        public var origin: CGPoint
        public var point: CGPoint
        /// Width over height to hold, when ⇧ asks for it.
        public var aspect: CGFloat?

        public init(handle: CropHandle, from origin: CGPoint, to point: CGPoint, aspect: CGFloat? = nil) {
            self.handle = handle
            self.origin = origin
            self.point = point
            self.aspect = aspect
        }

        var widthOnly: Bool {
            handle == .leading || handle == .trailing
        }
    }

    public func resized(_ command: AnnotationCommand, by drag: Drag) -> AnnotationCommand {
        let handle = drag.handle
        let aspect = drag.aspect
        let widthOnly = drag.widthOnly
        let start = local(drag.origin)
        let end = local(drag.point)
        let newBox = CropRectEditor.resized(
            box,
            handle: handle,
            translation: CGSize(width: end.x - start.x, height: end.y - start.y),
            aspect: aspect
        )
        guard newBox.width > 0, newBox.height > 0 else { return command }
        let scaled = SelectionResizer.scaled(command, from: box, to: newBox, widthOnly: widthOnly)

        let fixedBefore = Self.anchorOpposite(handle, in: box)
        let fixedAfter = Self.anchorOpposite(handle, in: newBox)
        let worldBefore = world(fixedBefore)
        let newCenter = CGPoint(x: newBox.midX, y: newBox.midY)
        let worldAfter = AnnotationRotation.rotate(fixedAfter, around: newCenter, radians: radians)
        let shift = CGSize(width: worldBefore.x - worldAfter.x, height: worldBefore.y - worldAfter.y)
        guard abs(shift.width) > 0.0001 || abs(shift.height) > 0.0001 else { return scaled }
        return SelectionResizer.scaled(
            scaled,
            from: newBox,
            to: newBox.offsetBy(dx: shift.width, dy: shift.height),
            widthOnly: false
        )
    }

    /// The point a resize from `handle` holds still: the opposite corner, or the middle
    /// of the opposite side.
    static func anchorOpposite(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        let x: CGFloat = if handle.moves(.leading) {
            rect.maxX
        } else if handle.moves(.trailing) {
            rect.minX
        } else {
            rect.midX
        }
        let y: CGFloat = if handle.moves(.top) {
            rect.maxY
        } else if handle.moves(.bottom) {
            rect.minY
        } else {
            rect.midY
        }
        return CGPoint(x: x, y: y)
    }
}
