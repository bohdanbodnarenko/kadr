import AppKit
import CoreGraphics
import Foundation

/// A bundled-looking practice photo, drawn locally so onboarding never needs a capture
/// or a network fetch (docs/03 §8.2).
enum OnboardingPracticeImage {
    /// Writes a fresh copy each time, so a previous session's annotations cannot leak in.
    static func makeWorkingCopy() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Kadr/Practice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("practice.png")
        guard let image = render(), let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// A quiet coastal scene: enough shape and contrast to try an arrow, a label and a blur.
    static func render(width: Int = 1600, height: Int = 1000) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        drawSky(in: context, bounds: bounds)
        drawSea(in: context, bounds: bounds)
        drawCliffs(in: context, bounds: bounds)
        drawPath(in: context, bounds: bounds)
        drawGrass(in: context, bounds: bounds)
        return context.makeImage()
    }

    private static func drawSky(in context: CGContext, bounds: CGRect) {
        let colors = [
            CGColor(red: 0.62, green: 0.78, blue: 0.92, alpha: 1),
            CGColor(red: 0.86, green: 0.90, blue: 0.94, alpha: 1)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: context.colorSpace,
            colors: colors,
            locations: [0, 1]
        ) else {
            return
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: bounds.maxY),
            end: CGPoint(x: 0, y: bounds.midY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func drawSea(in context: CGContext, bounds: CGRect) {
        let colors = [
            CGColor(red: 0.35, green: 0.58, blue: 0.72, alpha: 1),
            CGColor(red: 0.48, green: 0.68, blue: 0.76, alpha: 1)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: context.colorSpace,
            colors: colors,
            locations: [0, 1]
        ) else {
            return
        }
        let seaTop = bounds.height * 0.46
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: seaTop),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    private static func drawCliffs(in context: CGContext, bounds: CGRect) {
        context.setFillColor(CGColor(red: 0.72, green: 0.62, blue: 0.52, alpha: 1))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.width * 0.52, y: bounds.height * 0.46))
        path.addLine(to: CGPoint(x: bounds.width * 0.62, y: bounds.height * 0.62))
        path.addLine(to: CGPoint(x: bounds.width * 0.78, y: bounds.height * 0.58))
        path.addLine(to: CGPoint(x: bounds.width, y: bounds.height * 0.64))
        path.addLine(to: CGPoint(x: bounds.width, y: bounds.height * 0.46))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    private static func drawPath(in context: CGContext, bounds: CGRect) {
        context.setStrokeColor(CGColor(red: 0.78, green: 0.72, blue: 0.58, alpha: 1))
        context.setLineWidth(bounds.width * 0.035)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: bounds.width * 0.18, y: bounds.height * 0.08))
        context.addQuadCurve(
            to: CGPoint(x: bounds.width * 0.48, y: bounds.height * 0.42),
            control: CGPoint(x: bounds.width * 0.22, y: bounds.height * 0.32)
        )
        context.strokePath()
    }

    private static func drawGrass(in context: CGContext, bounds: CGRect) {
        context.setFillColor(CGColor(red: 0.45, green: 0.55, blue: 0.38, alpha: 1))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: bounds.height * 0.28))
        path.addQuadCurve(
            to: CGPoint(x: bounds.width * 0.55, y: bounds.height * 0.18),
            control: CGPoint(x: bounds.width * 0.22, y: bounds.height * 0.38)
        )
        path.addLine(to: CGPoint(x: bounds.width * 0.7, y: 0))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }
}
