import CoreGraphics
import Foundation

/// A mutable RGBA8 bitmap the mosaic works over.
///
/// A value rather than four loose parameters: every function in here needs all of them,
/// and a stray `bytesPerRow` in the wrong position reads pixels from the wrong row rather
/// than failing.
struct MutableBitmap {
    let pixels: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    func offset(x: Int, y: Int) -> Int {
        y * bytesPerRow + x * 4
    }
}

/// One RGBA pixel.
struct BitmapPixel {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
}

/// A mosaic whose every cell samples from its own randomly displaced point (docs/03 §3).
///
/// The security claim in docs/03 is that pixelation "defeats de-pixelation of predictable
/// grids". A plain mosaic does not: each cell holds the *average* of a known rectangle, so
/// an attacker who knows the font can render every candidate string, average it on the same
/// grid, and match. Shifting the whole grid by one random offset — which is what Kadr used
/// to do — costs the attacker one brute-forced parameter out of `cellSize²`, and nothing
/// more (docs/07 M3).
///
/// Per-cell displacement is what actually breaks the attack. Each cell is filled from a
/// point up to a cell away in an unrecorded direction, so the cell values no longer come
/// from a partition of the region at all: two adjacent cells may sample the same glyph
/// stroke, or skip one entirely. There is no grid to align to, and the displacements are
/// not recoverable from the output.
///
/// A CPU pass rather than a `CIKernel`: redaction regions are small, this runs once at
/// export, and a plain loop is far easier to argue about than a kernel — which matters more
/// than speed for the one piece of the editor with a security claim attached to it.
enum PixelateMosaic {
    /// Rewrites `bitmap` in place as a jittered mosaic.
    ///
    /// - Parameters:
    ///   - cellSize: the mosaic's cell edge in pixels; clamped to at least 2.
    ///   - generator: seeded in tests, random in production.
    static func apply(
        to bitmap: MutableBitmap,
        cellSize: Int,
        generator: inout SeededGenerator
    ) {
        let cell = max(cellSize, 2)
        guard bitmap.width > 0, bitmap.height > 0 else { return }

        // Sampling has to read the original pixels: reading the buffer as it is rewritten
        // would let one cell's colour bleed across the whole region.
        let byteCount = bitmap.bytesPerRow * bitmap.height
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        source.initialize(from: bitmap.pixels, count: byteCount)
        defer { source.deallocate() }

        // The grid itself starts at a random phase, so its lines are not at the region's
        // edge either. This is the old behaviour, kept — it is cheap, and it is one more
        // unknown on top of the per-cell displacement.
        let originX = -Int.random(in: 0 ..< cell, using: &generator)
        let originY = -Int.random(in: 0 ..< cell, using: &generator)

        var cellY = originY
        while cellY < bitmap.height {
            var cellX = originX
            while cellX < bitmap.width {
                let sample = samplePoint(
                    cellX: cellX,
                    cellY: cellY,
                    cell: cell,
                    in: bitmap,
                    generator: &generator
                )
                let offset = bitmap.offset(x: sample.x, y: sample.y)
                let colour = BitmapPixel(
                    red: source[offset],
                    green: source[offset + 1],
                    blue: source[offset + 2],
                    alpha: source[offset + 3]
                )
                fill(
                    bitmap,
                    xRange: max(cellX, 0) ..< min(cellX + cell, bitmap.width),
                    yRange: max(cellY, 0) ..< min(cellY + cell, bitmap.height),
                    colour: colour
                )
                cellX += cell
            }
            cellY += cell
        }
    }

    /// Where one cell reads its colour from: its centre, displaced by up to a cell in each
    /// direction, clamped into the region.
    private static func samplePoint(
        cellX: Int,
        cellY: Int,
        cell: Int,
        in bitmap: MutableBitmap,
        generator: inout SeededGenerator
    ) -> (x: Int, y: Int) {
        let jitterX = Int.random(in: -cell ... cell, using: &generator)
        let jitterY = Int.random(in: -cell ... cell, using: &generator)
        return (
            x: min(max(cellX + cell / 2 + jitterX, 0), bitmap.width - 1),
            y: min(max(cellY + cell / 2 + jitterY, 0), bitmap.height - 1)
        )
    }

    private static func fill(
        _ bitmap: MutableBitmap,
        xRange: Range<Int>,
        yRange: Range<Int>,
        colour: BitmapPixel
    ) {
        guard !xRange.isEmpty, !yRange.isEmpty else { return }
        for y in yRange {
            for x in xRange {
                let offset = bitmap.offset(x: x, y: y)
                bitmap.pixels[offset] = colour.red
                bitmap.pixels[offset + 1] = colour.green
                bitmap.pixels[offset + 2] = colour.blue
                bitmap.pixels[offset + 3] = colour.alpha
            }
        }
    }
}
