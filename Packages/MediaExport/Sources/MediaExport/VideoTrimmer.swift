import AVFoundation
import Foundation
import os
import Shared

/// What went wrong trimming a recording.
public enum TrimError: Error, Equatable, Sendable {
    case noVideoTrack
    /// The range asked for is empty, or lies outside the recording.
    case emptyRange
    case exportFailed(String)
    case cannotWrite(String)
}

/// The part of a recording to keep, in seconds from its start (docs/03 §1.8).
public struct TrimRange: Sendable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double {
        max(0, end - start)
    }

    /// The range as it applies to a recording `seconds` long, or nil if nothing is left.
    ///
    /// Clamping rather than refusing: a trim handle dragged to the very end of a movie
    /// reports a time a hair past the duration, and that is not a user error.
    public func clamped(to seconds: Double) -> TrimRange? {
        guard seconds > 0 else { return nil }
        let lower = min(max(start, 0), seconds)
        let upper = min(max(end, 0), seconds)
        guard upper - lower > 0.01 else { return nil }
        return TrimRange(start: lower, end: upper)
    }

    /// Whether this range is the whole recording, in which case there is nothing to do.
    public func isWhole(of seconds: Double) -> Bool {
        start <= 0.01 && end >= seconds - 0.01
    }
}

public protocol VideoTrimming: Sendable {
    func trim(movieAt url: URL, to range: TrimRange, destination: URL) async throws -> URL
}

/// Cuts a recording down to a range without re-encoding it (docs/03 §1.8).
///
/// Passthrough, always: the segments were written by the recorder in the codec the user
/// chose, and a trim is a container edit. Re-encoding would cost a generation of quality
/// and minutes of CPU to remove a few seconds of dead air at the top of a clip.
///
/// The consequence is that cuts land on key frames, so the result can start a fraction of
/// a second before the handle. That is the same behaviour QuickTime's own trim has, and it
/// is the right trade for a screen recording.
public struct PassthroughVideoTrimmer: VideoTrimming {
    private let logger = KadrLog.logger(.recording)

    public init() {}

    public func trim(movieAt url: URL, to range: TrimRange, destination: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard await (try? asset.loadTracks(withMediaType: .video).first) != nil else {
            throw TrimError.noVideoTrack
        }
        let seconds = try await CMTimeGetSeconds(asset.load(.duration))
        guard let range = range.clamped(to: seconds) else { throw TrimError.emptyRange }

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw TrimError.exportFailed("This recording cannot be trimmed without re-encoding it.")
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600)
        )

        let fileType = Self.fileType(for: destination)
        // Never overwrite: a trim writes a new file beside the original, and the original
        // is the only copy of the footage (docs/03 §2).
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TrimError.cannotWrite("A file already exists at \(destination.lastPathComponent).")
        }

        if #available(macOS 15.0, *) {
            do {
                try await session.export(to: destination, as: fileType)
            } catch {
                throw TrimError.exportFailed(error.localizedDescription)
            }
        } else {
            try await Self.exportLegacy(session, to: destination, as: fileType)
        }

        let kept = range.duration
        logger.info("Trimmed to \(kept, privacy: .public) s")
        return destination
    }

    /// macOS 14's export API, which reports through a completion handler.
    private static func exportLegacy(
        _ session: AVAssetExportSession,
        to destination: URL,
        as fileType: AVFileType
    ) async throws {
        session.outputURL = destination
        session.outputFileType = fileType
        await session.export()
        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw TrimError.exportFailed(
                session.error?.localizedDescription ?? "The trim could not be written."
            )
        }
    }

    /// The container to write, taken from the destination's extension.
    ///
    /// Passthrough can only write what the source's codecs fit into, and the caller names
    /// the destination after the source, so following the extension is right.
    static func fileType(for destination: URL) -> AVFileType {
        switch destination.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }
    }

    /// Where a trim of `url` should be written: beside it, clearly named, never over it.
    public static func destination(trimming url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = folder.appendingPathComponent("\(base) (Trimmed)").appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(base) (Trimmed \(counter))")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
