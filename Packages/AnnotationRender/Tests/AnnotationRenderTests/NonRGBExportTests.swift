import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// Exporting images that are not RGB: CMYK, grey (docs/18 ED-13).
@Suite("Non-RGB export")
struct NonRGBExportTests {
    private func makeImage(space: CGColorSpace, bitmapInfo: UInt32) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    @Test("CMYK and grey images get an sRGB canvas instead of none", arguments: [
        (CGColorSpaceCreateDeviceCMYK(), CGImageAlphaInfo.none.rawValue),
        (CGColorSpaceCreateDeviceGray(), CGImageAlphaInfo.none.rawValue)
    ])
    func fallsBackToSRGB(space: CGColorSpace, bitmapInfo: UInt32) throws {
        let image = try makeImage(space: space, bitmapInfo: bitmapInfo)
        let context = try #require(AnnotationExportRenderer.makeContext(width: 8, height: 8, matching: image))
        #expect(context.colorSpace?.model == .rgb)
    }

    @Test("A CMYK capture exports")
    func cmykExports() throws {
        let image = try makeImage(space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        let document = AnnotationDocument(baseImage: BaseImageReference(size: CGSize(width: 8, height: 8), scale: 1))
        let output = try AnnotationExportRenderer(objectShadowsEnabled: false)
            .render(baseImage: image, document: document)
        #expect(output.width == 8)
    }
}
