import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// Per-cell pixelate jitter (docs/03 §3, docs/07 M3, docs/09 U0.5).
///
/// docs/03 claims pixelation "defeats de-pixelation of predictable grids". These tests are
/// what makes that claim checkable: the striped fixture is exactly the input a single
/// global grid offset cannot obscure, because every cell lands on the same phase of the
/// pattern and comes out the same colour.
@Suite("Pixelate mosaic")
struct PixelateMosaicTests {
    private let width = 64
    private let height = 64
    private let cell = 8

    /// A buffer the tests own, so the mosaic can be run over it in place.
    private final class Bitmap {
        let pointer: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int
        var bytesPerRow: Int {
            width * 4
        }

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
            pointer.initialize(repeating: 0, count: width * height * 4)
        }

        deinit { pointer.deallocate() }

        func setPixel(x: Int, y: Int, red: UInt8, green: UInt8 = 0, blue: UInt8 = 0) {
            let offset = y * bytesPerRow + x * 4
            pointer[offset] = red
            pointer[offset + 1] = green
            pointer[offset + 2] = blue
            pointer[offset + 3] = 255
        }

        func red(x: Int, y: Int) -> UInt8 {
            pointer[y * bytesPerRow + x * 4]
        }

        var bytes: [UInt8] {
            Array(UnsafeBufferPointer(start: pointer, count: bytesPerRow * height))
        }
    }

    /// Vertical stripes with the same period as the mosaic's cells — the worst case for a
    /// grid-aligned mosaic, and what a line of text looks like to one.
    private func stripes() -> Bitmap {
        let bitmap = Bitmap(width: width, height: height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                bitmap.setPixel(x: x, y: y, red: (x / cell) % 2 == 0 ? 0 : 255)
            }
        }
        return bitmap
    }

    private func run(_ bitmap: Bitmap, seed: UInt64, cellSize: Int? = nil) {
        var generator = SeededGenerator(seed: seed)
        PixelateMosaic.apply(
            to: MutableBitmap(
                pixels: bitmap.pointer,
                width: bitmap.width,
                height: bitmap.height,
                bytesPerRow: bitmap.bytesPerRow
            ),
            cellSize: cellSize ?? cell,
            generator: &generator
        )
    }

    /// The M3 failure in one assertion.
    ///
    /// Against stripes of exactly one cell's width, a mosaic that averages a fixed grid gives
    /// every cell the same phase of the pattern, so every cell comes out one of at most two
    /// values — pure stripe colours when aligned, the same half-grey everywhere when not.
    /// That uniformity is what an attacker matches against. Windows displaced per cell cover
    /// a different share of each stripe, so the cells take many values.
    @Test("Cell-periodic content does not come back as a fixed grid", arguments: [1 as UInt64, 7, 99, 12345])
    func stripesAreScrambled(seed: UInt64) {
        let bitmap = stripes()
        run(bitmap, seed: seed)

        let values = Set((0 ..< width).map { bitmap.red(x: $0, y: 4) })
        #expect(
            values.count > 3,
            "cells came out \(values.sorted()) — the mosaic reproduced the grid it was meant to destroy"
        )
    }

    /// The "confetti" regression: a cell is an average of its window, never one sampled pixel.
    ///
    /// Sparse bright detail on a dark field — text on a terminal — must pixelate to a dark
    /// field faintly lifted by the strokes. Filling cells from single pixels scattered bright
    /// squares wherever a sample happened to land on a stroke.
    @Test("Sparse detail averages into its field instead of scattering bright cells", arguments: [2 as UInt64, 31, 777])
    func sparseDetailAverages(seed: UInt64) {
        let bitmap = Bitmap(width: width, height: height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                bitmap.setPixel(x: x, y: y, red: x % 4 == 0 && y % 4 == 0 ? 255 : 20)
            }
        }
        run(bitmap, seed: seed)

        let brightest = (0 ..< height).flatMap { y in (0 ..< width).map { bitmap.red(x: $0, y: y) } }.max() ?? 0
        #expect(brightest < 60, "a cell reached \(brightest): it copied a stroke instead of averaging")
    }

    /// The property that actually matters: cells do not all read the same phase, so the
    /// output is not a rigid function of the input grid.
    @Test("Two runs over the same content differ")
    func differentSeedsGiveDifferentMosaics() {
        let first = stripes()
        let second = stripes()
        run(first, seed: 1)
        run(second, seed: 2)
        #expect(first.bytes != second.bytes, "an unrecorded displacement is the whole defence")
    }

    @Test("The same seed gives the same mosaic")
    func seedIsDeterministic() {
        let first = stripes()
        let second = stripes()
        run(first, seed: 4242)
        run(second, seed: 4242)
        #expect(first.bytes == second.bytes)
    }

    /// Whatever the sampling does, the result still has to *look* pixelated: within one
    /// cell of the grid there is exactly one colour.
    @Test("Every whole cell is a single colour")
    func cellsAreFlat() {
        let bitmap = stripes()
        run(bitmap, seed: 8)

        // Cell boundaries are at an unknown phase, so check runs rather than fixed cells:
        // no row may contain more distinct runs than there are cells across it.
        for y in stride(from: 0, to: height, by: 7) {
            var runs = 1
            for x in 1 ..< width where bitmap.red(x: x, y: y) != bitmap.red(x: x - 1, y: y) {
                runs += 1
            }
            #expect(runs <= width / cell + 1, "row \(y) is not mosaicked into cells")
        }
    }

    /// Sampling must read the original pixels. Reading the buffer as it is rewritten makes
    /// one cell's colour march across the whole region.
    @Test("One cell's colour cannot flood the region")
    func samplingReadsTheOriginal() {
        let bitmap = Bitmap(width: width, height: height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                bitmap.setPixel(x: x, y: y, red: UInt8(y * 4 % 256))
            }
        }
        run(bitmap, seed: 3)

        let distinct = Set((0 ..< height).map { bitmap.red(x: 10, y: $0) })
        #expect(distinct.count > 2, "a gradient collapsed to one colour means cells sampled each other")
    }

    @Test("A cell size larger than the region still produces one flat block")
    func oversizedCell() {
        let bitmap = stripes()
        run(bitmap, seed: 5, cellSize: 4096)
        let first = bitmap.red(x: 0, y: 0)
        #expect((0 ..< height).allSatisfy { y in (0 ..< width).allSatisfy { bitmap.red(x: $0, y: y) == first } })
    }

    @Test("A degenerate cell size is clamped, not divided by")
    func zeroCellIsClamped() {
        let bitmap = stripes()
        run(bitmap, seed: 6, cellSize: 0)
        #expect(bitmap.bytes.count == width * height * 4)
    }
}
