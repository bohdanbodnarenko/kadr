import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import os
import Shared

/// Draws overlays into recorded frames (docs/04 §4.3).
///
/// Into the frames, before the writer — not onto the screen. That is the whole design
/// decision: a click halo drawn on screen would be visible to the user and to anyone
/// watching over their shoulder, would appear in *other* apps' recordings, and could not
/// be turned off after the fact. Compositing into the pipeline means the overlay exists
/// only in the file (docs/03 §1.8 accept list).
struct FrameCompositor: Sendable {
    private let logger = KadrLog.logger(.recording)

    /// Draws an overlay into a frame, in place.
    ///
    /// In place because the alternative is allocating a second full-resolution buffer per
    /// frame, which at 1080p60 is 500 MB a second of churn. SCK's buffers are
    /// IOSurface-backed and writable, so the drawing happens where the pixels already are.
    func draw(_ overlay: RecordingOverlay, into pixelBuffer: CVPixelBuffer) {
        guard !overlay.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return }

        // CoreVideo buffers are top-left origin; CGContext is bottom-left. Flipping once
        // here lets every overlay position be expressed the way the rest of the app thinks
        // about the frame. Anything with a top and a bottom of its own — text, the webcam
        // picture — flips back over its own rect via `drawUpright`.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        for click in overlay.clicks {
            drawClick(click, in: context)
        }
        if let keystrokes = overlay.keystrokes, !keystrokes.isEmpty {
            drawKeystrokes(
                keystrokes,
                position: overlay.keystrokePosition,
                in: context,
                size: CGSize(width: width, height: height)
            )
        }
        if let webcam = overlay.webcamFrame {
            drawWebcam(
                webcam,
                isCircular: overlay.webcamIsCircular,
                in: context,
                size: CGSize(width: width, height: height)
            )
        }
    }

    // MARK: - Clicks

    /// A ring that expands and fades, which reads as a click without hiding what was
    /// clicked (docs/03 §1.8).
    private func drawClick(_ click: ClickPulse, in context: CGContext) {
        let maximumRadius: CGFloat = 44
        let radius = 10 + maximumRadius * CGFloat(click.progress)
        let alpha = 1 - click.progress

        let colour = click.isRightClick
            ? CGColor(srgbRed: 1, green: 0.7, blue: 0.1, alpha: alpha * 0.9)
            : CGColor(srgbRed: 1, green: 0.25, blue: 0.2, alpha: alpha * 0.9)

        let rect = CGRect(
            x: click.position.x - radius,
            y: click.position.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.setStrokeColor(colour)
        context.setLineWidth(4 * (1 - CGFloat(click.progress) * 0.6))
        context.strokeEllipse(in: rect)

        // A solid dot at the point itself, so a fast click is still visible when the ring
        // has barely started.
        context.setFillColor(CGColor(srgbRed: 1, green: 0.25, blue: 0.2, alpha: alpha * 0.5))
        context.fillEllipse(in: CGRect(
            x: click.position.x - 6,
            y: click.position.y - 6,
            width: 12,
            height: 12
        ))
    }

    // MARK: - Keystrokes

    private func drawKeystrokes(
        _ text: String,
        position: KeystrokePosition,
        in context: CGContext,
        size: CGSize
    ) {
        let fontSize = max(20, size.height * 0.035)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        let padding = fontSize * 0.6
        let pillWidth = bounds.width + padding * 2
        let pillHeight = bounds.height + padding
        let margin = size.height * 0.06

        // The context is flipped to the frame's own top-left origin, so the bottom of the
        // picture is the *larger* y.
        let bottom = size.height - margin - pillHeight
        let origin = switch position {
        case .bottomCentre:
            CGPoint(x: (size.width - pillWidth) / 2, y: bottom)
        case .bottomLeading:
            CGPoint(x: margin, y: bottom)
        case .topCentre:
            CGPoint(x: (size.width - pillWidth) / 2, y: margin)
        }

        let pill = CGRect(origin: origin, size: CGSize(width: pillWidth, height: pillHeight))
        context.setFillColor(CGColor(gray: 0, alpha: 0.72))
        context.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pillHeight / 2,
            cornerHeight: pillHeight / 2,
            transform: nil
        ))
        context.fillPath()

        // Glyphs have a top and a bottom, so they are drawn the right way up over the pill
        // rather than mirrored by the frame-wide flip.
        drawUpright(in: pill, context: context) { context in
            context.textPosition = CGPoint(
                x: pill.minX + padding - bounds.minX,
                y: pill.minY + padding / 2 - bounds.minY
            )
            CTLineDraw(line, context)
        }
    }

    /// Runs `body` with the frame-wide vertical flip undone over `rect`.
    ///
    /// The flip that makes overlay positions top-left-origin also mirrors anything with an
    /// intrinsic orientation. Reflecting about the rect's own middle cancels it, leaving
    /// the rect exactly where it was.
    private func drawUpright(
        in rect: CGRect,
        context: CGContext,
        body: (CGContext) -> Void
    ) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        body(context)
        context.restoreGState()
    }

    // MARK: - Webcam

    private func drawWebcam(
        _ image: CGImage,
        isCircular: Bool,
        in context: CGContext,
        size: CGSize
    ) {
        let side = min(size.width, size.height) * 0.22
        let margin = size.height * 0.04
        // Bottom-right, in the frame's top-left-origin space.
        let rect = CGRect(
            x: size.width - side - margin,
            y: size.height - side - margin,
            width: side,
            height: side
        )

        let path = isCircular
            ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(roundedRect: rect, cornerWidth: side * 0.12, cornerHeight: side * 0.12, transform: nil)
        // Fill the frame rather than letterboxing it: a PiP with black bars looks broken.
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let drawRect = aspect > 1
            ? CGRect(
                x: rect.midX - rect.height * aspect / 2,
                y: rect.minY,
                width: rect.height * aspect,
                height: rect.height
            )
            : CGRect(
                x: rect.minX,
                y: rect.midY - rect.width / aspect / 2,
                width: rect.width,
                height: rect.width / aspect
            )
        drawUpright(in: rect, context: context) { context in
            context.addPath(path)
            context.clip()
            context.draw(image, in: drawRect)
        }

        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        context.setLineWidth(max(2, side * 0.02))
        context.strokePath()
    }
}
