import CoreGraphics
import CoreVideo
import Foundation

/// How big to ask the camera's frames to be (PRD §8).
nonisolated enum WebcamOutputSizing {
    /// The camera's aspect ratio at `shortEdge`, or nil when the camera is already no
    /// bigger than that — the camera is never asked to upscale.
    ///
    /// Dimensions are even, because the capture pipeline's scaler works in 2×2 blocks.
    static func size(nativeWidth: Int, nativeHeight: Int, shortEdge: Int) -> (width: Int, height: Int)? {
        let nativeShort = min(nativeWidth, nativeHeight)
        guard nativeShort > 0, shortEdge > 0, shortEdge < nativeShort else { return nil }
        let factor = Double(shortEdge) / Double(nativeShort)
        let width = even(Double(nativeWidth) * factor)
        let height = even(Double(nativeHeight) * factor)
        guard width < nativeWidth || height < nativeHeight else { return nil }
        return (width, height)
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}

/// A `CGImage` over a camera frame's own memory (PRD §8).
///
/// Built without CoreImage or VideoToolbox, which the agent does not link (docs/10 R2.1),
/// and without `CGContext.makeImage`, which copied every camera frame in full. The image
/// keeps the pixel buffer alive and read-locked until the image itself goes — which is
/// when the next camera frame replaces it — so the bytes it points at cannot move.
nonisolated enum WebcamFrameImage {
    static func image(wrapping pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else {
            return nil
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let size = bytesPerRow * height
        // Balanced by the release callback, which is the provider's last word on the bytes.
        let retained = Unmanaged.passRetained(pixelBuffer).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: retained,
            data: base,
            size: size,
            releaseData: { info, _, _ in
                guard let info else { return }
                let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(info).takeRetainedValue()
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
        ) else {
            Unmanaged<CVPixelBuffer>.fromOpaque(retained).release()
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: deviceRGB,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
}
