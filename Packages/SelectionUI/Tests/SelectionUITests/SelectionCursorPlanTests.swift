import CoreGraphics
import Testing
@testable import SelectionUI

/// The pointer the selection screen shows (docs/18 CAP P3).
@Suite("Selection cursor")
struct SelectionCursorPlanTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let selection = CGRect(x: 100, y: 100, width: 200, height: 150)

    private func shapes(
        window: Bool = false,
        eyedropper: Bool = false,
        selection: CGRect? = nil
    ) -> [SelectionCursorPlan.Shape] {
        SelectionCursorPlan(
            bounds: bounds,
            isWindowMode: window,
            isEyedropper: eyedropper,
            adjustableSelection: selection,
            handleRadius: 8
        ).regions.map(\.shape)
    }

    @Test("Drawing a selection is a crosshair everywhere")
    func area() {
        #expect(shapes() == [.crosshair])
    }

    @Test("Window mode points at what a click will take")
    func window() {
        #expect(shapes(window: true) == [.pointingHand])
    }

    @Test("The eyedropper keeps its crosshair, even over a selection")
    func eyedropper() {
        #expect(shapes(eyedropper: true, selection: selection) == [.crosshair])
    }

    @Test("A selection waiting for confirmation can be grabbed and resized at each corner")
    func adjustable() {
        #expect(shapes(selection: selection) == [
            .crosshair, .openHand,
            .resize(.topLeft), .resize(.topRight), .resize(.bottomLeft), .resize(.bottomRight)
        ])
    }

    @Test("Each corner's resize region is centred on the corner", arguments: [
        (SelectionHandleLayerGroup.Corner.topLeft, CGPoint(x: 100, y: 100)),
        (.topRight, CGPoint(x: 300, y: 100)),
        (.bottomLeft, CGPoint(x: 100, y: 250)),
        (.bottomRight, CGPoint(x: 300, y: 250))
    ])
    func cornerRegions(corner: SelectionHandleLayerGroup.Corner, centre: CGPoint) throws {
        let plan = SelectionCursorPlan(
            bounds: bounds,
            isWindowMode: false,
            isEyedropper: false,
            adjustableSelection: selection,
            handleRadius: 8
        )
        let region = try #require(plan.regions.first { $0.shape == .resize(corner) })
        #expect(region.rect == CGRect(x: centre.x - 8, y: centre.y - 8, width: 16, height: 16))
    }
}
