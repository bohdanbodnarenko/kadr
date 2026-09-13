import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A synthetic horizontally scrolling page for stitcher tests (CleanShot §4.8).
struct HorizontalScrollFixture {
    let name: String
    let frameWidth: Int
    let frameHeight: Int
    let leading: Int
    let trailing: Int
    let scrollSteps: [Int]
    let drawColumn: @Sendable (_ x: Int, _ column: UnsafeMutableBufferPointer<UInt8>, _ height: Int) -> Void

    var pageWidth: Int {
        scrollSteps.reduce(0, +) + frameWidth - leading - trailing
    }

    var scrollPositions: [Int] {
        scrollSteps.reduce(into: [0]) { positions, step in
            positions.append(positions[positions.count - 1] + step)
        }
    }

    static let timeline = HorizontalScrollFixture(
        name: "Horizontal timeline",
        frameWidth: 520,
        frameHeight: 320,
        leading: 48,
        trailing: 0,
        scrollSteps: [180, 240, 96, 300, 144],
        drawColumn: { x, column, height in
            HorizontalScrollFixture.fill(column, height: height, level: 245)
            guard x % 18 < 9 else { return }
            let segment = x / 18
            let length = 80 + Int(HorizontalScrollFixture.hash(UInt64(segment)) % 120)
            HorizontalScrollFixture.bar(column, from: 40, to: 40 + length, level: 40)
        }
    )

    func golden() -> CGImage {
        let contentWidth = (scrollPositions.last ?? 0) + frameWidth - leading - trailing
        return makeImage(width: leading + contentWidth, height: frameHeight) { x, column in
            if x < leading {
                chrome(column, x: x, level: 200)
            } else {
                drawColumn(x - leading, column, frameHeight)
            }
        }
    }

    func frames() -> [CGImage] {
        scrollPositions.map { scroll in
            makeImage(width: frameWidth, height: frameHeight) { x, column in
                if x < leading {
                    chrome(column, x: x, level: 200)
                } else if x >= frameWidth - trailing {
                    chrome(column, x: x, level: 210)
                } else {
                    drawColumn(scroll + x - leading, column, frameHeight)
                }
            }
        }
    }

    func writeFrames(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try frames().enumerated().map { index, image in
            let url = directory.appendingPathComponent(String(format: "frame-%04d.png", index))
            guard let sink = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(sink, image, nil)
            guard CGImageDestinationFinalize(sink) else { throw CocoaError(.fileWriteUnknown) }
            return url
        }
    }

    private func chrome(_ column: UnsafeMutableBufferPointer<UInt8>, x: Int, level: UInt8) {
        Self.fill(column, height: frameHeight, level: level)
        Self.bar(column, from: 16, to: 16 + 40 + Int(Self.hash(UInt64(x)) % 80), level: 60)
    }

    private static func fill(_ column: UnsafeMutableBufferPointer<UInt8>, height: Int, level: UInt8) {
        for y in 0 ..< height {
            column[y * 4] = level
            column[y * 4 + 1] = level
            column[y * 4 + 2] = level
            column[y * 4 + 3] = 255
        }
    }

    private static func bar(
        _ column: UnsafeMutableBufferPointer<UInt8>,
        from: Int,
        to: Int,
        level: UInt8
    ) {
        let upper = min(to, column.count / 4)
        guard from < upper else { return }
        for y in from ..< upper {
            column[y * 4] = level
            column[y * 4 + 1] = level
            column[y * 4 + 2] = level
            column[y * 4 + 3] = 255
        }
    }

    private static func hash(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    private func makeImage(
        width: Int,
        height: Int,
        column draw: (Int, UnsafeMutableBufferPointer<UInt8>) -> Void
    ) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for x in 0 ..< width {
                var column = [UInt8](repeating: 0, count: height * 4)
                column.withUnsafeMutableBufferPointer { columnBuffer in
                    draw(x, columnBuffer)
                    for y in 0 ..< height {
                        let source = y * 4
                        let destination = y * bytesPerRow + x * 4
                        buffer[destination] = columnBuffer[source]
                        buffer[destination + 1] = columnBuffer[source + 1]
                        buffer[destination + 2] = columnBuffer[source + 2]
                        buffer[destination + 3] = columnBuffer[source + 3]
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { fatalError("Could not build a horizontal scroll fixture image") }
        return image
    }
}
