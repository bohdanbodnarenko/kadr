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

/// A pixelation that looks like one, and that a de-pixelation attack cannot line up with
/// (docs/03 §3, docs/07 M3).
///
/// **The look.** Each cell is the *average* of a cell-sized window, the way every mosaic
/// people recognise is made. The previous version filled each cell from one randomly
/// chosen pixel: over text that is mostly background with the occasional stroke, so the
/// result was a flat field scattered with bright squares — noise, not pixelation.
///
/// **The defence.** A plain mosaic averages a fixed partition of the region, so an attacker
/// who knows the font renders candidate strings, averages them on the same grid and matches
/// (Depix). Here nothing lines up:
///
/// * the grid starts at a random phase, so its lines are not at the region's edge;
/// * every cell averages its own window, displaced by up to half a cell in an unrecorded
///   direction, so the averages are not over a partition at all — neighbouring windows
///   overlap or leave gaps, differently for every cell;
/// * every cell is tinted by a few levels of noise, so even a correctly guessed window does
///   not reproduce the exact value an attacker would match against.
///
/// None of the displacements or tints are stored, and export draws a fresh seed each time.
///
/// A CPU pass rather than a `CIKernel`: regions are small, and a plain loop is far easier to
/// argue about than a kernel — which matters for the one piece of the editor with a security
/// claim attached to it.
enum PixelateMosaic {
    /// The largest per-cell tint, in 8-bit levels: invisible to the eye, fatal to an exact match.
    static let noiseLevels = 3

    /// Rewrites `bitmap` in place as a jittered, averaged mosaic.
    ///
    /// - Parameters:
    ///   - cellSize: the mosaic's cell edge in pixels; clamped to at least 2.
    ///   - generator: seeded in tests and previews, random in export.
    static func apply(
        to bitmap: MutableBitmap,
        cellSize: Int,
        generator: inout SeededGenerator
    ) {
        let cell = max(cellSize, 2)
        guard bitmap.width > 0, bitmap.height > 0 else { return }

        // Averaging has to read the original pixels: reading the buffer as it is rewritten
        // would let one cell's colour bleed into the next window.
        let byteCount = bitmap.bytesPerRow * bitmap.height
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        source.initialize(from: bitmap.pixels, count: byteCount)
        defer { source.deallocate() }
        let original = MutableBitmap(
            pixels: source,
            width: bitmap.width,
            height: bitmap.height,
            bytesPerRow: bitmap.bytesPerRow
        )

        let originX = -Int.random(in: 0 ..< cell, using: &generator)
        let originY = -Int.random(in: 0 ..< cell, using: &generator)

        var cellY = originY
        while cellY < bitmap.height {
            var cellX = originX
            while cellX < bitmap.width {
                let window = sampleWindow(cellX: cellX, cellY: cellY, cell: cell, in: bitmap, generator: &generator)
                let colour = tinted(average(of: original, window: window), generator: &generator)
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

    /// The pixels one cell averages: its own footprint, displaced by up to half a cell in
    /// each direction, kept whole and inside the region.
    static func sampleWindow(
        cellX: Int,
        cellY: Int,
        cell: Int,
        in bitmap: MutableBitmap,
        generator: inout SeededGenerator
    ) -> (xRange: Range<Int>, yRange: Range<Int>) {
        let reach = cell / 2
        let jitterX = Int.random(in: -reach ... reach, using: &generator)
        let jitterY = Int.random(in: -reach ... reach, using: &generator)
        let windowWidth = min(cell, bitmap.width)
        let windowHeight = min(cell, bitmap.height)
        let x = min(max(cellX + jitterX, 0), bitmap.width - windowWidth)
        let y = min(max(cellY + jitterY, 0), bitmap.height - windowHeight)
        return (x ..< x + windowWidth, y ..< y + windowHeight)
    }

    private static func average(
        of bitmap: MutableBitmap,
        window: (xRange: Range<Int>, yRange: Range<Int>)
    ) -> BitmapPixel {
        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0
        for y in window.yRange {
            var offset = bitmap.offset(x: window.xRange.lowerBound, y: y)
            for _ in window.xRange {
                red += Int(bitmap.pixels[offset])
                green += Int(bitmap.pixels[offset + 1])
                blue += Int(bitmap.pixels[offset + 2])
                alpha += Int(bitmap.pixels[offset + 3])
                offset += 4
            }
        }
        let count = max(window.xRange.count * window.yRange.count, 1)
        return BitmapPixel(
            red: UInt8(red / count),
            green: UInt8(green / count),
            blue: UInt8(blue / count),
            alpha: UInt8(alpha / count)
        )
    }

    /// One tint per cell, the same on every channel so the colour does not shift, and kept
    /// within the alpha a premultiplied pixel allows.
    private static func tinted(_ colour: BitmapPixel, generator: inout SeededGenerator) -> BitmapPixel {
        let delta = Int.random(in: -noiseLevels ... noiseLevels, using: &generator)
        let ceiling = Int(colour.alpha)
        func shift(_ channel: UInt8) -> UInt8 {
            UInt8(min(max(Int(channel) + delta, 0), ceiling))
        }
        return BitmapPixel(
            red: shift(colour.red),
            green: shift(colour.green),
            blue: shift(colour.blue),
            alpha: colour.alpha
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
            var offset = bitmap.offset(x: xRange.lowerBound, y: y)
            for _ in xRange {
                bitmap.pixels[offset] = colour.red
                bitmap.pixels[offset + 1] = colour.green
                bitmap.pixels[offset + 2] = colour.blue
                bitmap.pixels[offset + 3] = colour.alpha
                offset += 4
            }
        }
    }
}
