import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// Lengths that scale with the capture (docs/09 U1.1).
@Suite("Beautify metrics")
struct BeautifyMetricTests {
    @Test("A relative metric is a fraction of the shortest edge")
    func relativeResolves() {
        #expect(BeautifyMetric.relative(0.1).resolved(shortestEdge: 400) == 40)
        #expect(BeautifyMetric.relative(0.1).resolved(shortestEdge: 4000) == 400)
    }

    @Test("An absolute metric ignores the capture entirely")
    func absoluteResolves() {
        #expect(BeautifyMetric.points(30).resolved(shortestEdge: 400) == 30)
        #expect(BeautifyMetric.points(30).resolved(shortestEdge: 4000) == 30)
    }

    @Test("Negative lengths are floored at zero", arguments: [
        BeautifyMetric.relative(-1),
        BeautifyMetric.points(-40)
    ])
    func negativesAreFloored(metric: BeautifyMetric) {
        #expect(metric.resolved(shortestEdge: 100) == 0)
        #expect(metric.isZero)
    }

    @Test("A zero-sized capture resolves to nothing rather than crashing")
    func zeroEdge() {
        #expect(BeautifyMetric.relative(0.5).resolved(shortestEdge: 0) == 0)
        #expect(BeautifyMetric.relative(0.5).fraction(shortestEdge: 0) == 0)
    }

    @Test("The fraction of an absolute metric depends on what it is measured against")
    func absoluteAsFraction() {
        #expect(BeautifyMetric.points(50).fraction(shortestEdge: 200) == 0.25)
    }

    // MARK: - Persistence

    @Test("A metric round-trips", arguments: [
        BeautifyMetric.relative(0.08),
        BeautifyMetric.points(24),
        BeautifyMetric.zero
    ])
    func roundTrip(metric: BeautifyMetric) throws {
        let data = try JSONEncoder().encode(metric)
        #expect(try JSONDecoder().decode(BeautifyMetric.self, from: data) == metric)
    }

    /// Documents written before U1.1 stored these fields as bare numbers of points. They
    /// have to keep opening, and they have to keep meaning the same thing.
    @Test("A bare number decodes as points, so older documents still open")
    func bareNumberIsPoints() throws {
        let decoded = try JSONDecoder().decode(BeautifyMetric.self, from: Data("48".utf8))
        #expect(decoded == .points(48))
    }

    @Test("An unrecognized shape decodes as nothing rather than throwing")
    func unknownShape() throws {
        let decoded = try JSONDecoder().decode(BeautifyMetric.self, from: Data("{\"future\":1}".utf8))
        #expect(decoded == .zero)
    }
}

/// Which corners round, and which square off against a canvas edge (docs/09 U1.1).
@Suite("Beautify corners")
struct BeautifyCornerTests {
    @Test("With nothing stuck, every corner is round")
    func nothingStuck() {
        let corners = BeautifyCorners.resolving(radius: 12, stuck: .none)
        #expect(corners.isUniform)
        #expect(corners.topLeading == 12)
    }

    /// A rounded corner sitting on the canvas boundary shows a notch of background where
    /// the capture should be running off the edge — so a corner squares when *either* of
    /// its edges is stuck.
    @Test("A stuck bottom edge squares both bottom corners")
    func stuckBottom() {
        let corners = BeautifyCorners.resolving(radius: 12, stuck: .bottom)
        #expect(corners.bottomLeading == 0)
        #expect(corners.bottomTrailing == 0)
        #expect(corners.topLeading == 12)
        #expect(corners.topTrailing == 12)
    }

    @Test("A stuck corner squares three of the four")
    func stuckCorner() {
        let corners = BeautifyCorners.resolving(radius: 12, stuck: [.bottom, .trailing])
        #expect(corners.topLeading == 12)
        #expect(corners.topTrailing == 0)
        #expect(corners.bottomLeading == 0)
        #expect(corners.bottomTrailing == 0)
    }

    @Test("Every edge stuck is a plain rectangle")
    func allStuck() {
        let corners = BeautifyCorners.resolving(radius: 12, stuck: [.top, .bottom, .leading, .trailing])
        #expect(corners == .square)
    }

    @Test("A radius is clamped to half the shorter side")
    func clamping() {
        let corners = BeautifyCorners(uniform: 500).clamped(to: CGRect(x: 0, y: 0, width: 200, height: 80))
        #expect(corners.largest == 40)
    }

    @Test("Alignment decides which edges are stuck", arguments: BeautifyCornerTests.stuckCases)
    func stuckEdgesForAlignment(testCase: (alignment: BeautifyAlignment, edges: BeautifyEdges)) {
        #expect(BeautifyEdges.stuck(by: testCase.alignment) == testCase.edges)
    }

    static let stuckCases: [(alignment: BeautifyAlignment, edges: BeautifyEdges)] = [
        (.center, .none),
        (.top, .top),
        (.bottom, .bottom),
        (.leading, .leading),
        (.trailing, .trailing),
        (.topLeading, [.top, .leading]),
        (.topTrailing, [.top, .trailing]),
        (.bottomLeading, [.bottom, .leading]),
        (.bottomTrailing, [.bottom, .trailing])
    ]
}

/// The curated fills (docs/09 U1.1).
@Suite("Beautify palette")
struct BeautifyPaletteTests {
    @Test("Sixteen of each, as specified")
    func counts() {
        #expect(BeautifyPalette.solids.count == 16)
        #expect(BeautifyPalette.gradients.count == 16)
    }

    @Test("Every curated gradient has a designed midpoint")
    func gradientsAreThreeStop() {
        for ramp in BeautifyPalette.gradients {
            #expect(ramp.middle != nil)
            #expect(ramp.stops.count == 3)
        }
    }

    @Test("Stops come out in order, so CGGradient accepts them")
    func stopsAreMonotonic() {
        for ramp in BeautifyPalette.gradients {
            let locations = ramp.stops.map(\.location)
            #expect(locations == locations.sorted())
            #expect(locations.first == 0)
            #expect(locations.last == 1)
        }
    }

    @Test("A two-stop ramp is still valid")
    func twoStopRamp() {
        let ramp = BeautifyGradient(start: .white, end: .black)
        #expect(ramp.stops.count == 2)
    }

    @Test("A middle stop cannot sit on top of an end stop")
    func middleIsClamped() {
        #expect(BeautifyGradient(start: .white, middle: .black, middleLocation: 0, end: .white)
            .middleLocation > 0)
        #expect(BeautifyGradient(start: .white, middle: .black, middleLocation: 1, end: .white)
            .middleLocation < 1)
    }

    @Test("No curated fill points at a file, let alone a URL")
    func nothingToDownload() {
        for colour in BeautifyPalette.solids {
            #expect(colour.alpha == 1)
        }
    }
}
