import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// The gradient behind a progressive blur (docs/09 U1.3).
///
/// The mask is the whole effect, so it is the part worth testing without rendering: a
/// falloff that runs backwards, or a focus radius that ends up outside the falloff, gives
/// CoreImage a mask it will happily apply and nobody can explain.
@Suite("Progressive blur")
struct ProgressiveBlurTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - The spec keeps itself sane

    @Test("The focus never ends up outside the falloff")
    func focusIsInsideFalloff() {
        let inverted = ProgressiveBlurSpec(focusRadius: 0.9, falloffRadius: 0.2)
        #expect(inverted.focusRadius < inverted.falloffRadius)
        #expect(inverted.focusRadius == 0.2)
    }

    @Test("A zero-width gradient is widened into an actual gradient")
    func hardEdgeIsWidened() {
        let spec = ProgressiveBlurSpec(focusRadius: 0.5, falloffRadius: 0.5)
        #expect(spec.falloffRadius > spec.focusRadius)
        #expect(spec.falloffRadius - spec.focusRadius >= ProgressiveBlurSpec.minimumFalloff)
    }

    @Test("A negative focus is floored at the centre")
    func negativeFocus() {
        #expect(ProgressiveBlurSpec(focusRadius: -3).focusRadius == 0)
    }

    @Test("A blur with no radius does nothing and knows it")
    func zeroRadiusIsIdentity() {
        #expect(ProgressiveBlurSpec(radius: .zero).isIdentity)
        #expect(!ProgressiveBlurSpec.focus.isIdentity)
    }

    // MARK: - Resolving against a rect

    @Test("The centre resolves in the target's own coordinates")
    func centreResolves() {
        let mask = ProgressiveBlurMask.resolve(ProgressiveBlurSpec(), in: rect)
        #expect(mask.center == CGPoint(x: 200, y: 150))
    }

    @Test("An off-centre focus lands where it was asked to")
    func offCentreFocus() {
        let spec = ProgressiveBlurSpec(center: CGPoint(x: 0.25, y: 0.75))
        let mask = ProgressiveBlurMask.resolve(spec, in: rect)
        #expect(mask.center == CGPoint(x: 100, y: 225))
    }

    /// The radius scales with the capture, like every other beautify metric — so the same
    /// preset softens a phone screenshot and a 5K one by the same proportion.
    @Test("The blur radius is relative to the shortest edge", arguments: [
        CGSize(width: 400, height: 300),
        CGSize(width: 4000, height: 3000)
    ])
    func radiusScales(size: CGSize) {
        let spec = ProgressiveBlurSpec(radius: .relative(0.05))
        let mask = ProgressiveBlurMask.resolve(spec, in: CGRect(origin: .zero, size: size))
        #expect(mask.blurRadius == min(size.width, size.height) * 0.05)
    }

    /// The falloff reaches to the corner rather than to the narrow side, so "75%" means
    /// most of the way out whatever the aspect ratio.
    @Test("The falloff is measured to the corner")
    func falloffReachesTheCorner() {
        let spec = ProgressiveBlurSpec(focusRadius: 0, falloffRadius: 1)
        let mask = ProgressiveBlurMask.resolve(spec, in: rect)
        #expect(abs(mask.outerRadius - hypot(400, 300) / 2) < 0.001)
    }

    @Test("The ramp always runs outwards, never backwards")
    func rampIsOrdered() {
        for focus in stride(from: 0.0, through: 1.0, by: 0.1) {
            for falloff in stride(from: 0.0, through: 1.0, by: 0.1) {
                let spec = ProgressiveBlurSpec(focusRadius: focus, falloffRadius: falloff)
                let mask = ProgressiveBlurMask.resolve(spec, in: rect)
                #expect(mask.outerRadius > mask.innerRadius, "focus \(focus), falloff \(falloff)")
            }
        }
    }

    @Test("A directional ramp runs along its angle", arguments: [CGFloat(0), 90, 180, 270])
    func directionalAngle(angle: CGFloat) {
        let spec = ProgressiveBlurSpec(shape: .directional, angleDegrees: angle)
        let mask = ProgressiveBlurMask.resolve(spec, in: rect)

        let run = CGPoint(x: mask.end.x - mask.start.x, y: mask.end.y - mask.start.y)
        let radians = angle * .pi / 180
        // The ramp's direction should match the requested angle.
        #expect(abs(run.x - cos(radians) * hypot(run.x, run.y)) < 0.01)
        #expect(abs(run.y - sin(radians) * hypot(run.x, run.y)) < 0.01)
    }

    @Test("A radial mask says it is radial and a directional one does not")
    func shapeIsCarried() {
        #expect(ProgressiveBlurMask.resolve(ProgressiveBlurSpec(shape: .radial), in: rect).isRadial)
        #expect(!ProgressiveBlurMask.resolve(ProgressiveBlurSpec(shape: .directional), in: rect).isRadial)
    }

    @Test("Inversion is carried to the mask rather than being applied twice")
    func inversionIsCarried() {
        #expect(ProgressiveBlurMask.resolve(.obscureCentre, in: rect).isInverted)
        #expect(!ProgressiveBlurMask.resolve(.focus, in: rect).isInverted)
    }

    @Test("A degenerate rect resolves rather than dividing by zero")
    func zeroRect() {
        let mask = ProgressiveBlurMask.resolve(.focus, in: .zero)
        #expect(mask.blurRadius >= 0)
        #expect(mask.outerRadius >= mask.innerRadius)
    }

    // MARK: - Persistence

    @Test("A blur round-trips", arguments: [
        ProgressiveBlurSpec.focus,
        .fade,
        .obscureCentre
    ])
    func roundTrips(spec: ProgressiveBlurSpec) throws {
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(ProgressiveBlurSpec.self, from: data) == spec)
    }

    @Test("A spec with no fields at all decodes to the default")
    func emptyObject() throws {
        let spec = try JSONDecoder().decode(ProgressiveBlurSpec.self, from: Data("{}".utf8))
        #expect(spec.shape == .radial)
        #expect(spec.extent == .clipped)
        #expect(!spec.isInverted)
    }

    /// The distinction that matters most: a decorative blur and a redaction are different
    /// types on purpose, so a gradient can never reach the code that makes a secret
    /// unrecoverable.
    @Test("A progressive blur is not a redaction")
    func blurIsNotARedaction() {
        let command = AnnotationCommand.progressiveBlur(.focus)
        #expect(command.redactionForTesting == nil)
        #expect(!command.isSelectable)
        #expect(AnnotationTool.progressiveBlur.isCanvasChrome)
    }
}

extension AnnotationCommand {
    /// The redaction this command carries, if it is one. Mirrors the renderer's own
    /// accessor so the test can assert a blur is never mistaken for one.
    var redactionForTesting: RedactionSpec? {
        if case let .redaction(spec) = self {
            return spec
        }
        return nil
    }
}
