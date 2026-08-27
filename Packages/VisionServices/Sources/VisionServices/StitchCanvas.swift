import CoreGraphics
import Foundation
import os
import Shared

/// The bitmap a stitched page is drawn into.
///
/// A 30,000-pixel page is around 140 MB. Holding that on the heap of a process that also
/// holds Vision's models is how a helper ends up being the reason the machine swaps, so
/// past a threshold the bitmap is a memory-mapped scratch file instead: the same pixels,
/// but pages the kernel can evict and reclaim on its own terms (docs/03 §1.6 accept list).
final class Canvas {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private(set) var context: CGContext?

    private var mapped: UnsafeMutableRawPointer?
    private var mappedLength = 0
    private var scratchURL: URL?
    private let logger = KadrLog.logger(.capture)

    init(width: Int, height: Int, memoryMapped: Bool) throws {
        precondition(width > 0 && height > 0, "a canvas needs a size")
        self.width = width
        self.height = height
        bytesPerRow = width * 4

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        if memoryMapped, let mapping = try? Self.map(bytes: bytesPerRow * height) {
            mapped = mapping.pointer
            mappedLength = mapping.length
            scratchURL = mapping.url
        }

        context = CGContext(
            data: mapped,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        )
        guard context != nil else { throw ScrollStitcher.Failure.couldNotAllocate }
    }

    /// The finished pixels, without copying them.
    ///
    /// `CGContext.makeImage()` duplicates the bitmap, which for a memory-mapped strip
    /// would put the whole thing back on the heap — the one thing this class exists to
    /// avoid. Wrapping the buffer in a provider hands ImageIO the same pages.
    func makeImage() -> CGImage? {
        guard let context, let data = mapped ?? context.data else { return nil }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: data,
            size: bytesPerRow * height,
            releaseData: { _, _, _ in }
        ) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: context.bitmapInfo.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Releases the context and deletes the scratch file. Idempotent.
    func dispose() {
        context = nil
        if let mapped, mappedLength > 0 {
            munmap(mapped, mappedLength)
        }
        mapped = nil
        mappedLength = 0
        if let scratchURL {
            try? FileManager.default.removeItem(at: scratchURL)
        }
        scratchURL = nil
    }

    deinit {
        dispose()
    }

    private struct Mapping {
        let pointer: UnsafeMutableRawPointer
        let length: Int
        let url: URL
    }

    /// Creates a scratch file of `bytes` and maps it.
    ///
    /// The file is unlinked from the directory as soon as it is open, so a crash mid-stitch
    /// cannot leave a hundred megabytes behind in the temporary directory.
    private static func map(bytes: Int) throws -> Mapping {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr-Stitch-\(UUID().uuidString).bin")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw ScrollStitcher.Failure.couldNotAllocate }
        defer { close(descriptor) }

        guard ftruncate(descriptor, off_t(bytes)) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw ScrollStitcher.Failure.couldNotAllocate
        }
        let pointer = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let pointer, pointer != MAP_FAILED else {
            try? FileManager.default.removeItem(at: url)
            throw ScrollStitcher.Failure.couldNotAllocate
        }
        return Mapping(pointer: pointer, length: bytes, url: url)
    }
}
