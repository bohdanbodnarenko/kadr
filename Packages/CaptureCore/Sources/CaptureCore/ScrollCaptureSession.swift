import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import os
import ScreenCaptureKit
import Shared
import UniformTypeIdentifiers

/// Grabs the frames of a scrolling capture while the user scrolls (docs/03 §1.6, docs/04 §4.4).
///
/// A low-frame-rate `SCStream` over the selected rect, writing every frame straight to a
/// session directory. Frames go to disk rather than into an array for the obvious reason:
/// a two-minute scroll of a long page is hundreds of full-resolution frames, and holding
/// those is how a menu bar app ends up using a gigabyte. The stitcher reads them back one
/// at a time.
///
/// Nothing here needs a permission the app does not already have — that is the whole point
/// of the assisted tier (docs/03 §1.6).
public actor ScrollCaptureSession {
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    private var stream: SCStream?
    private var output: ScrollStreamOutput?
    private var consumeTask: Task<Void, Never>?

    public private(set) var directory: URL?
    public private(set) var framePaths: [URL] = []
    public private(set) var pixelSize = PixelSize(width: 0, height: 0)
    private var isCapturing = false
    private var captureAxis: ScrollAxis = .vertical
    private var excludedWindowIDs: Set<CGWindowID> = []

    /// Called on the main actor as each frame lands, for the growing-strip preview and the
    /// settle detection the auto tier needs.
    private var onFrame: (@Sendable (ScrollFrameNote) -> Void)?
    /// Called when macOS ends the stream while the user had not asked to stop — a display
    /// unplugged, the grant withdrawn — so the caller can stitch what it has and say so
    /// rather than wait on a capture that will never grow (docs/18 CAP-8).
    private var onInterrupted: (@Sendable () -> Void)?
    /// True between Stop and the last buffered frame being written.
    private var isStopping = false

    public init() {}

    public func setExcludedWindowIDs(_ ids: Set<CGWindowID>) {
        excludedWindowIDs = ids
    }

    /// What the caller learns about a frame without being handed the frame.
    public struct ScrollFrameNote: Sendable {
        public let index: Int
        public let url: URL
        public let axis: ScrollAxis
        public let rowProfile: RowProfile
        public let columnProfile: ColumnProfile
    }

    public var frameCount: Int {
        framePaths.count
    }

    /// Starts grabbing frames of `region` on `displayID`.
    public func start(
        region: DisplayRect,
        on displayID: CGDirectDisplayID,
        axis: ScrollAxis = .vertical,
        frameRate: Int = 8,
        onInterrupted: (@Sendable () -> Void)? = nil,
        onFrame: @escaping @Sendable (ScrollFrameNote) -> Void
    ) async throws {
        guard !isCapturing else {
            throw CaptureError.captureFailed(code: 0, description: "A scrolling capture is already running")
        }
        guard !region.isEmpty else { throw CaptureError.emptyRegion }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        // A scroll capture runs for seconds while the user scrolls, which is plenty of
        // time for a card to appear over the region and be stitched into the result
        // (docs/07 LOW, docs/10 R3.2).
        let excluded = CaptureEngine.windows(matching: excludedWindowIDs, in: content)
        let filter = CaptureEngine.filter(for: display, excluding: excluded)
        let geometry = DisplayGeometry(
            displayID: displayID,
            frame: DisplayRect(cgRect: display.frame),
            scale: DisplayScale(CGFloat(filter.pointPixelScale))
        )
        guard let clamped = geometry.clamped(region) else { throw CaptureError.regionOutsideDisplay }
        let local = geometry.localRect(for: clamped)
        let pixels = geometry.pixels(for: local)
        guard !pixels.isEmpty else { throw CaptureError.emptyRegion }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.frameFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.directory = directory
        self.onFrame = onFrame
        self.onInterrupted = onInterrupted
        captureAxis = axis
        pixelSize = PixelSize(width: pixels.width, height: pixels.height)
        framePaths = []

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local.cgRect
        configuration.destinationRect = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        configuration.width = pixels.width
        configuration.height = pixels.height
        // Low frame rate on purpose: the user is scrolling by hand, and every extra frame
        // is another file to write and another to align. Eight a second is more than
        // enough overlap at any human scroll speed.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let output = ScrollStreamOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)

        self.stream = stream
        self.output = output
        isCapturing = true

        consumeTask = Task { [weak self] in
            for await box in output.buffers {
                await self?.write(box)
            }
            // The stream only finishes on its own when macOS stopped it.
            await self?.streamEnded()
        }

        do {
            try await stream.startCapture()
        } catch {
            isCapturing = false
            throw CaptureError.mapping(error)
        }
        logger.info("Scrolling capture started at \(pixels.width, privacy: .public)×\(pixels.height, privacy: .public)")
    }

    /// Stops the stream and returns the frames, in order.
    @discardableResult
    public func stop() async -> [URL] {
        guard isCapturing, !isStopping else { return framePaths }
        isStopping = true

        // Drain rather than cancel: the last frames buffered on SCK's queue are the end
        // of the page, and dropping them cut the stitch short (docs/18 CAP-8).
        try? await stream?.stopCapture()
        output?.finish()
        await consumeTask?.value
        isCapturing = false
        isStopping = false
        stream = nil
        output = nil
        consumeTask = nil
        onFrame = nil
        onInterrupted = nil

        logger.info("Scrolling capture stopped with \(self.framePaths.count, privacy: .public) frames")
        return framePaths
    }

    private func streamEnded() {
        guard isCapturing, !isStopping else { return }
        logger.error("Scrolling capture stream stopped by the system")
        onInterrupted?()
    }

    /// The prefix every session's frame folder carries in the temporary directory.
    public static let frameFolderPrefix = "Kadr-Scroll-"

    /// Deletes frame folders a crashed session left behind. Called once at launch, when no
    /// session can be running (docs/18 §4.2 P3).
    @discardableResult
    public static func sweepOrphanedFrames(in temporary: URL = FileManager.default.temporaryDirectory) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(frameFolderPrefix) {
            if (try? manager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Stops and deletes everything the session wrote.
    public func discard() async {
        await stop()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        framePaths = []
    }

    /// Writes one frame to disk and tells the caller about it.
    ///
    /// PNG rather than a raw dump: the frames are read back by ImageIO in the helper, and
    /// a screenshot of a text page compresses to a fraction of its raw size — which
    /// matters when there are two hundred of them.
    private func write(_ box: UncheckedSendableBox<CMSampleBuffer>) {
        guard isCapturing, let directory else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(box.value) else { return }

        let state = signposter.beginInterval("scroll frame")
        defer { signposter.endInterval("scroll frame", state) }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

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
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let image = context.makeImage()
        else { return }

        let index = framePaths.count
        let url = directory.appendingPathComponent(String(format: "frame-%05d.png", index))
        guard let sink = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else { return }

        framePaths.append(url)
        guard let onFrame, let profiles = Self.profiles(of: image) else { return }
        onFrame(ScrollFrameNote(
            index: index,
            url: url,
            axis: captureAxis,
            rowProfile: profiles.row,
            columnProfile: profiles.column
        ))
    }

    private struct FrameProfiles {
        let row: RowProfile
        let column: ColumnProfile
    }

    /// The summaries the caller aligns against, built here so the frame itself never
    /// leaves this actor.
    private static func profiles(of image: CGImage) -> FrameProfiles? {
        let width = image.width
        let height = image.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let made = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard made else { return nil }
        return gray.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return FrameProfiles(
                row: RowProfile(grayscale: base, width: width, height: height, bytesPerRow: width),
                column: ColumnProfile(grayscale: base, width: width, height: height, bytesPerRow: width)
            )
        }
    }
}

/// The `nonisolated` fast path off ScreenCaptureKit's queue (docs/04 §4.3).
///
/// It forwards buffers and nothing else; writing a PNG on this queue would stall the
/// stream and drop the frames the stitch depends on.
private final class ScrollStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.bohdanbodnarenko.kadr.scroll.samples", qos: .userInitiated)
    let buffers: AsyncStream<UncheckedSendableBox<CMSampleBuffer>>
    private let continuation: AsyncStream<UncheckedSendableBox<CMSampleBuffer>>.Continuation

    override init() {
        (buffers, continuation) = AsyncStream.makeStream(
            of: UncheckedSendableBox<CMSampleBuffer>.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        super.init()
    }

    deinit {
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        // Complete frames only: SCK also sends status-only buffers when nothing changed.
        guard sampleBuffer.isComplete else { return }
        continuation.yield(UncheckedSendableBox(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish()
    }
}

private extension CMSampleBuffer {
    /// Whether SCK marked this frame as carrying new pixels.
    var isComplete: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
