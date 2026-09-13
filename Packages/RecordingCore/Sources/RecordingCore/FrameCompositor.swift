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

    /// How to describe one of ScreenCaptureKit's buffers to CoreGraphics (docs/11 S0.5).
    ///
    /// The bits per component were hard-coded to 8 while the engine switches the stream to
    /// `ARGB2101010LEPacked` for an HDR recording — and because both formats are four bytes
    /// per pixel, `CGContext` accepted the wrong description and quietly reinterpreted
    /// 10-bit data as 8888. HDR and click halos are two independent switches in the same
    /// settings pane, so the corruption needed nothing unusual to reach: turn both on.
    struct BitmapLayout {
        let bitsPerComponent: Int
        let bitmapInfo: UInt32

        /// Nil for a format this does not know how to draw into, which is a refusal rather
        /// than a guess.
        init?(pixelFormat: OSType) {
            switch pixelFormat {
            case kCVPixelFormatType_32BGRA:
                bitsPerComponent = 8
                bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            case kCVPixelFormatType_ARGB2101010LEPacked:
                // Ten bits per component in the same four bytes, with the two spare bits
                // where the alpha would be — so there is no alpha to premultiply into.
                bitsPerComponent = 10
                bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            default:
                return nil
            }
        }
    }

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
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let layout = BitmapLayout(pixelFormat: format) else {
            // Loudly, and without drawing (docs/11 S0.5). Guessing at an unknown layout is
            // how the HDR bug happened: a wrong-but-plausible description of the memory
            // succeeds and corrupts every pixel it touches.
            logger.error("Refusing to draw overlays into pixel format \(format, privacy: .public)")
            return
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: layout.bitsPerComponent,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: layout.bitmapInfo
              )
        else {
            logger.error("Could not describe a \(format, privacy: .public) frame to CoreGraphics")
            return
        }

        // CoreVideo buffers are top-left origin; CGContext is bottom-left. Flipping once
        // here lets every overlay position be expressed the way the rest of the app thinks
        // about the frame. Anything with a top and a bottom of its own — text, the webcam
        // picture — flips back over its own rect via `drawUpright`.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        for click in overlay.clicks {
            drawClick(click, in: context, overlay: overlay)
        }
        if let keystrokes = overlay.keystrokes, !keystrokes.isEmpty {
            drawKeystrokes(
                keystrokes,
                position: overlay.keystrokePosition,
                appearance: overlay.keystrokeAppearance,
                scale: overlay.keystrokeScale,
                in: context,
                size: CGSize(width: width, height: height)
            )
        }
        if let webcam = overlay.webcamFrame {
            drawWebcam(
                webcam,
                isCircular: overlay.webcamIsCircular,
                sizeFraction: overlay.webcamSizeFraction,
                fillsFrame: overlay.webcamFillsFrame,
                in: context,
                size: CGSize(width: width, height: height)
            )
        }
    }

    // MARK: - Clicks

    /// A ring that expands and fades, which reads as a click without hiding what was
    /// clicked (docs/03 §1.8).
    private func drawClick(_ click: ClickPulse, in context: CGContext, overlay: RecordingOverlay) {
        let maximumRadius: CGFloat = 44 * overlay.clickScale
        let radius = (10 + maximumRadius * CGFloat(click.progress))
        let alpha = 1 - click.progress

        let colour = click.isRightClick
            ? CGColor(srgbRed: 1, green: 0.7, blue: 0.1, alpha: alpha * 0.9)
            : CGColor(
                srgbRed: overlay.clickRed,
                green: overlay.clickGreen,
                blue: overlay.clickBlue,
                alpha: alpha * 0.9
            )

        let rect = CGRect(
            x: click.position.x - radius,
            y: click.position.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        if overlay.clickFilled {
            context.setFillColor(colour)
            context.fillEllipse(in: rect)
        } else {
            context.setStrokeColor(colour)
            context.setLineWidth(4 * overlay.clickScale * (1 - CGFloat(click.progress) * 0.6))
            context.strokeEllipse(in: rect)
        }

        // A solid dot at the point itself, so a fast click is still visible when the ring
        // has barely started.
        context.setFillColor(CGColor(
            srgbRed: overlay.clickRed,
            green: overlay.clickGreen,
            blue: overlay.clickBlue,
            alpha: alpha * 0.5
        ))
        let dot = 6 * overlay.clickScale
        context.fillEllipse(in: CGRect(
            x: click.position.x - dot,
            y: click.position.y - dot,
            width: dot * 2,
            height: dot * 2
        ))
    }

    // MARK: - Keystrokes

    private func drawKeystrokes(
        _ text: String,
        position: KeystrokePosition,
        appearance: OverlayChromeAppearance,
        scale: CGFloat,
        in context: CGContext,
        size: CGSize
    ) {
        let fontSize = max(20, size.height * 0.035) * scale
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let ink: CGColor = switch appearance {
        case .dark: CGColor(gray: 1, alpha: 1)
        case .light: CGColor(gray: 0.08, alpha: 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): ink
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
        switch appearance {
        case .dark:
            context.setFillColor(CGColor(gray: 0, alpha: 0.72))
        case .light:
            context.setFillColor(CGColor(gray: 1, alpha: 0.86))
        }
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
        sizeFraction: CGFloat,
        fillsFrame: Bool,
        in context: CGContext,
        size: CGSize
    ) {
        let rect: CGRect
        if fillsFrame {
            rect = CGRect(origin: .zero, size: size)
        } else {
            let side = min(size.width, size.height) * sizeFraction
            let margin = size.height * 0.04
            // Bottom-right, in the frame's top-left-origin space.
            rect = CGRect(
                x: size.width - side - margin,
                y: size.height - side - margin,
                width: side,
                height: side
            )
        }

        let corner = min(rect.width, rect.height) * 0.12
        let path = isCircular
            ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(
                roundedRect: rect,
                cornerWidth: fillsFrame ? min(24, corner) : corner,
                cornerHeight: fillsFrame ? min(24, corner) : corner,
                transform: nil
            )
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
        context.setStrokeColor(CGColor(gray: 1, alpha: fillsFrame ? 0 : 0.85))
        context.setLineWidth(max(2, min(rect.width, rect.height) * 0.02))
        context.strokePath()
    }
}
