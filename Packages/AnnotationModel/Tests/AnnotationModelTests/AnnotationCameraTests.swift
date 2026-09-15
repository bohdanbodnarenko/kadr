import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import AnnotationModel

/// The projective transform behind the perspective camera (docs/09 U1.2).
///
/// Table-driven because the failures here are silent: a homography with a sign error still
/// produces a plausible-looking quad, and the only way to notice is that clicking on the
/// tilted image selects the wrong thing. Round-tripping every point through the forward and
/// inverse maps is what catches that.
@Suite("Homography")
struct HomographyTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func isClose(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.001) -> Bool {
        abs(lhs.x - rhs.x) < tolerance && abs(lhs.y - rhs.y) < tolerance
    }

    @Test("The identity maps every point to itself", arguments: [
        CGPoint.zero,
        CGPoint(x: 100, y: 50),
        CGPoint(x: -30, y: 900)
    ])
    func identityMapsToItself(point: CGPoint) throws {
        #expect(try #require(Homography.identity.map(point)) == point)
    }

    @Test("A rect mapped to its own corners is the identity in effect")
    func rectToItself() throws {
        let transform = Homography.rect(rect, to: CameraQuad(rect: rect))
        let mapped = try #require(transform.map(CGPoint(x: 123, y: 45)))
        #expect(isClose(mapped, CGPoint(x: 123, y: 45)))
    }

    @Test("Each corner of the rect lands on the matching corner of the quad")
    func cornersMatch() throws {
        let quad = CameraQuad(
            topLeft: CGPoint(x: 40, y: 10),
            topRight: CGPoint(x: 380, y: 30),
            bottomRight: CGPoint(x: 340, y: 280),
            bottomLeft: CGPoint(x: 10, y: 260)
        )
        let transform = Homography.rect(rect, to: quad)

        #expect(try isClose(#require(transform.map(CGPoint(x: 0, y: 0))), quad.topLeft))
        #expect(try isClose(#require(transform.map(CGPoint(x: 400, y: 0))), quad.topRight))
        #expect(try isClose(#require(transform.map(CGPoint(x: 400, y: 300))), quad.bottomRight))
        #expect(try isClose(#require(transform.map(CGPoint(x: 0, y: 300))), quad.bottomLeft))
    }

    /// The property the whole editing story rests on: whatever the camera does, a click can
    /// be traced back to the pixel under it.
    @Test("Every point survives a round trip through the inverse", arguments: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 400, y: 300),
        CGPoint(x: 200, y: 150),
        CGPoint(x: 17, y: 291),
        CGPoint(x: 399, y: 1)
    ])
    func roundTrip(point: CGPoint) throws {
        let quad = CameraQuad(
            topLeft: CGPoint(x: 60, y: 20),
            topRight: CGPoint(x: 370, y: 55),
            bottomRight: CGPoint(x: 330, y: 290),
            bottomLeft: CGPoint(x: 25, y: 250)
        )
        let transform = Homography.rect(rect, to: quad)
        let inverse = try #require(transform.inverted)

        let there = try #require(transform.map(point))
        let back = try #require(inverse.map(there))
        #expect(isClose(back, point, tolerance: 0.01), "\(point) came back as \(back)")
    }

    @Test("A parallelogram is handled by the affine branch, not by dividing by zero")
    func parallelogramIsAffine() throws {
        // A pure shear: no vanishing point, so the projective terms must drop out.
        let quad = CameraQuad(
            topLeft: CGPoint(x: 50, y: 0),
            topRight: CGPoint(x: 450, y: 0),
            bottomRight: CGPoint(x: 400, y: 300),
            bottomLeft: CGPoint(x: 0, y: 300)
        )
        let transform = Homography.unitSquare(to: quad)
        #expect(transform.m31 == 0)
        #expect(transform.m32 == 0)

        let full = Homography.rect(rect, to: quad)
        #expect(try isClose(#require(full.map(CGPoint(x: 400, y: 0))), quad.topRight))
    }

    @Test("A degenerate transform has no inverse rather than a nonsense one")
    func degenerateHasNoInverse() {
        let flat = Homography(m11: 1, m12: 0, m13: 0, m21: 2, m22: 0, m23: 0, m31: 0, m32: 0, m33: 1)
        #expect(flat.inverted == nil)
    }

    @Test("A CATransform3D maps corners the same way as the 3×3")
    func caTransformMatchesMap() throws {
        let quad = CameraQuad(
            topLeft: CGPoint(x: 40, y: 10),
            topRight: CGPoint(x: 380, y: 30),
            bottomRight: CGPoint(x: 340, y: 280),
            bottomLeft: CGPoint(x: 10, y: 260)
        )
        let transform = Homography.rect(rect, to: quad)
        let layer = transform.caTransform3D
        for point in [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 400, y: 0),
            CGPoint(x: 400, y: 300),
            CGPoint(x: 0, y: 300),
            CGPoint(x: 123, y: 45)
        ] {
            let mapped = try #require(transform.map(point))
            let layered = try #require(Homography.map(layer, point))
            #expect(isClose(mapped, layered, tolerance: 0.05), "\(point): \(mapped) vs \(layered)")
        }
    }

    @Test("Composition applies the right-hand transform first")
    func compositionOrder() throws {
        let translate = Homography(m11: 1, m12: 0, m13: 10, m21: 0, m22: 1, m23: 0, m31: 0, m32: 0, m33: 1)
        let scale = Homography(m11: 2, m12: 0, m13: 0, m21: 0, m22: 2, m23: 0, m31: 0, m32: 0, m33: 1)

        // Scale after translate: (0,0) -> (10,0) -> (20,0).
        let scaleThenTranslate = scale.concatenating(translate)
        #expect(try #require(scaleThenTranslate.map(.zero)) == CGPoint(x: 20, y: 0))

        // Translate after scale: (0,0) -> (0,0) -> (10,0).
        let translateThenScale = translate.concatenating(scale)
        #expect(try #require(translateThenScale.map(.zero)) == CGPoint(x: 10, y: 0))
    }

    @Test("A point on the horizon has no image on screen")
    func horizonPointIsUnmapped() {
        let projective = Homography(m11: 1, m12: 0, m13: 0, m21: 0, m22: 1, m23: 0, m31: 1, m32: 0, m33: 0)
        #expect(projective.map(.zero) == nil, "w = 0 means the point is at infinity")
    }

    @Test("A zero-sized rect gives up rather than dividing by zero")
    func zeroRect() {
        #expect(Homography.rect(.zero, to: CameraQuad(rect: .zero)) == .identity)
    }
}

/// The camera that produces those quads (docs/09 U1.2).
@Suite("Annotation camera")
struct AnnotationCameraTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func geometry(_ spec: AnnotationCameraSpec) -> AnnotationCameraGeometry {
        AnnotationCameraGeometry(spec: spec, contentRect: rect)
    }

    private func isClose(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.01) -> Bool {
        abs(lhs.x - rhs.x) < tolerance && abs(lhs.y - rhs.y) < tolerance
    }

    @Test("An untouched camera leaves the capture exactly where it was")
    func identityIsIdentity() {
        let quad = geometry(.identity).quad
        #expect(isClose(quad.topLeft, CGPoint(x: 0, y: 0)))
        #expect(isClose(quad.topRight, CGPoint(x: 400, y: 0)))
        #expect(isClose(quad.bottomRight, CGPoint(x: 400, y: 300)))
        #expect(isClose(quad.bottomLeft, CGPoint(x: 0, y: 300)))
        #expect(AnnotationCameraSpec.identity.isIdentity)
    }

    /// The field of view is a lens, not a zoom: changing it alone must not resize an
    /// untilted picture, or the two controls fight each other.
    @Test("Field of view alone does not resize the picture", arguments: [
        CGFloat(10), 25, 45, 80, 120
    ])
    func fieldOfViewDoesNotScale(fov: CGFloat) {
        let quad = geometry(AnnotationCameraSpec(fieldOfViewDegrees: fov)).quad
        #expect(isClose(quad.topLeft, CGPoint(x: 0, y: 0)))
        #expect(isClose(quad.bottomRight, CGPoint(x: 400, y: 300)))
    }

    /// What perspective *means*: the edge leaning away is shorter than the one leaning
    /// towards the viewer. A skew would keep them equal.
    @Test("A tilt makes the far edge shorter than the near one")
    func tiltConverges() {
        let quad = geometry(AnnotationCameraSpec(tiltDegrees: 35)).quad
        let topWidth = quad.topRight.x - quad.topLeft.x
        let bottomWidth = quad.bottomRight.x - quad.bottomLeft.x
        #expect(topWidth < bottomWidth, "top \(topWidth), bottom \(bottomWidth)")
    }

    @Test("A negative tilt converges the other way")
    func negativeTiltConverges() {
        let quad = geometry(AnnotationCameraSpec(tiltDegrees: -35)).quad
        #expect(quad.topRight.x - quad.topLeft.x > quad.bottomRight.x - quad.bottomLeft.x)
    }

    @Test("An orbit converges the vertical edges")
    func orbitConverges() {
        let quad = geometry(AnnotationCameraSpec(orbitDegrees: 35)).quad
        let leftHeight = quad.bottomLeft.y - quad.topLeft.y
        let rightHeight = quad.bottomRight.y - quad.topRight.y
        #expect(abs(leftHeight - rightHeight) > 1, "an orbit should foreshorten one side")
    }

    /// A wider lens exaggerates depth at the same angle — the reason the knob exists.
    @Test("A wider lens exaggerates the same tilt")
    func wideLensExaggerates() {
        func convergence(_ fov: CGFloat) -> CGFloat {
            let quad = geometry(AnnotationCameraSpec(tiltDegrees: 30, fieldOfViewDegrees: fov)).quad
            return (quad.bottomRight.x - quad.bottomLeft.x) / (quad.topRight.x - quad.topLeft.x)
        }
        #expect(convergence(90) > convergence(20))
    }

    @Test("Roll is a plain rotation, so opposite edges stay equal")
    func rollDoesNotConverge() {
        let quad = geometry(AnnotationCameraSpec(rollDegrees: 20)).quad
        let topLength = hypot(quad.topRight.x - quad.topLeft.x, quad.topRight.y - quad.topLeft.y)
        let bottomLength = hypot(
            quad.bottomRight.x - quad.bottomLeft.x,
            quad.bottomRight.y - quad.bottomLeft.y
        )
        #expect(abs(topLength - bottomLength) < 0.01)
    }

    @Test("Zoom scales about the centre")
    func zoomScalesAboutTheCentre() {
        let quad = geometry(AnnotationCameraSpec(zoom: 2)).quad
        #expect(isClose(quad.topLeft, CGPoint(x: -200, y: -150)))
        #expect(isClose(quad.bottomRight, CGPoint(x: 600, y: 450)))
    }

    @Test("Pan is a fraction of the content, so it carries between captures")
    func panIsRelative() {
        let quad = geometry(AnnotationCameraSpec(pan: CGPoint(x: 0.25, y: -0.5))).quad
        #expect(isClose(quad.topLeft, CGPoint(x: 100, y: -150)))
    }

    // MARK: - Hit-testing through the projection

    /// The behaviour that makes a tilted image *editable* rather than a picture of an
    /// image: a click maps back to the pixel under the pointer.
    @Test("A click on the tilted image finds the pixel under it", arguments: [
        CGPoint(x: 10, y: 10),
        CGPoint(x: 200, y: 150),
        CGPoint(x: 390, y: 290),
        CGPoint(x: 0, y: 300)
    ])
    func hitTestingRoundTrips(contentPoint: CGPoint) throws {
        let camera = geometry(AnnotationCameraSpec(tiltDegrees: 25, orbitDegrees: -18, rollDegrees: 6))
        let onScreen = try #require(camera.canvasPoint(from: contentPoint))
        let back = try #require(camera.contentPoint(from: onScreen))
        #expect(isClose(back, contentPoint, tolerance: 0.05), "\(contentPoint) came back as \(back)")
    }

    @Test("Every camera the model can hold is invertible", arguments: [
        AnnotationCameraSpec.identity,
        .lean,
        .hero,
        .overhead,
        AnnotationCameraSpec(tiltDegrees: 999, orbitDegrees: -999, rollDegrees: 400, zoom: 99),
        AnnotationCameraSpec(fieldOfViewDegrees: 0),
        AnnotationCameraSpec(fieldOfViewDegrees: 999)
    ])
    func everySpecIsInvertible(spec: AnnotationCameraSpec) {
        #expect(geometry(spec).inverse != nil, "\(spec) produced an uninvertible projection")
    }

    // MARK: - Clamping

    @Test("Angles and zoom are clamped in the model, not at render time")
    func clamping() {
        let extreme = AnnotationCameraSpec(
            tiltDegrees: 300,
            orbitDegrees: -300,
            fieldOfViewDegrees: 500,
            zoom: 100
        )
        #expect(extreme.tiltDegrees == AnnotationCameraSpec.maximumTilt)
        #expect(extreme.orbitDegrees == -AnnotationCameraSpec.maximumTilt)
        #expect(extreme.fieldOfViewDegrees == AnnotationCameraSpec.maximumFieldOfView)
        #expect(extreme.zoom == AnnotationCameraSpec.maximumZoom)
    }

    @Test("Roll is not clamped, because every angle of it is meaningful")
    func rollIsFree() {
        #expect(AnnotationCameraSpec(rollDegrees: 400).rollDegrees == 400)
    }

    // MARK: - Persistence

    @Test("A camera round-trips", arguments: [
        AnnotationCameraSpec.identity,
        .lean,
        .hero,
        .overhead
    ])
    func roundTrips(spec: AnnotationCameraSpec) throws {
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(AnnotationCameraSpec.self, from: data) == spec)
    }

    @Test("A camera with no fields at all decodes to the identity")
    func emptyObjectDecodes() throws {
        let spec = try JSONDecoder().decode(AnnotationCameraSpec.self, from: Data("{}".utf8))
        #expect(spec.isIdentity)
        #expect(spec.fieldOfViewDegrees == 45)
    }

    @Test("A zero-sized capture produces its own rect rather than nothing")
    func zeroContent() {
        let camera = AnnotationCameraGeometry(spec: .hero, contentRect: .zero)
        #expect(camera.quad == CameraQuad(rect: .zero))
    }
}
