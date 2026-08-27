import CoreGraphics
import Foundation
import ImageIO
import Shared
import UniformTypeIdentifiers
@testable import HistoryKit

/// Writes a unique PNG so content-addressed storage does not collapse fixtures together.
func writeTestImage(width: Int = 32, height: Int = 16, seed: Int) throws -> URL {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    let red = CGFloat((seed * 37) % 255) / 255
    let green = CGFloat((seed * 17) % 255) / 255
    let blue = CGFloat((seed * 53) % 255) / 255
    context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-history-\(seed)-\(UUID().uuidString).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Could not create a test image destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write the test image")
    }
    return url
}

func makeHistoryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-history-root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func ingestDraft(seed: Int, capturedAt: Date = Date(), kind: HistoryItemKind = .image) throws -> HistoryIngest {
    let url = try writeTestImage(seed: seed)
    return HistoryIngest(
        sourceURL: url,
        kind: kind,
        pixelSize: PixelSize(width: 32, height: 16),
        applicationName: "Tester",
        capturedAt: capturedAt,
        originalFilename: "capture-\(seed).png"
    )
}
