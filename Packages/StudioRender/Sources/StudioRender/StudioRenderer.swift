import AVFoundation
import CoreImage
import Foundation
import os
import Shared
import StudioSession

/// Renders a studio edit to a movie (docs/09 U3.3, PRD §8).
///
/// Edit-side AVFoundation only: nothing here captures anything, and this package has never
/// heard of a display. The capture stays in the agent with the TCC grant, and the render
/// runs wherever the editor is — which is a process that can be killed without taking the
/// menu bar with it.
///
/// A reader-and-writer pass rather than `AVVideoComposition`, because the studio's camera
/// moves between frames and its overlays are drawn from a telemetry stream. A video
/// composition would have to be handed the same per-frame closure anyway, and would take
/// away the ability to say how far along the render is.
public struct StudioRenderer: Sendable {
    private let logger = KadrLog.logger(.recording)
    private static let signposter = OSSignposter(logger: KadrLog.logger(.recording))

    public init() {}

    public enum RenderError: Error, Equatable, Sendable {
        case noVideoTrack
        case couldNotCreateWriter(String)
        case couldNotCreateReader(String)
        case writingFailed(String)
        /// The reader stopped before the end of the composition (docs/11 S0.4).
        ///
        /// Its own case rather than `writingFailed`, because it is the failure that used to
        /// have no symptom: the writer was perfectly healthy and produced a well-formed file
        /// of whatever arrived before the reader died. Naming it separately is what stops the
        /// next person reading "writing failed" and looking at the writer.
        case readingFailed(String)
        case cancelled
    }

    /// How the output is encoded.
    public struct Options: Sendable, Hashable {
        public var codec: AVVideoCodecType
        public var frameRate: Int
        /// Bits per second, or nil to let the size and rate decide.
        public var bitRate: Int?
        /// Applied to the computed (or explicit) bit rate. 1 is High; lower is a smaller file.
        public var bitRateMultiplier: Double
        public var fileType: AVFileType
        public var includeAudio: Bool
        /// Caps the longest output edge, in pixels. Nil leaves the edit's own size.
        public var maxLongestEdge: Int?

        public init(
            codec: AVVideoCodecType = .hevc,
            frameRate: Int = 60,
            bitRate: Int? = nil,
            bitRateMultiplier: Double = 1,
            fileType: AVFileType = .mov,
            includeAudio: Bool = true,
            maxLongestEdge: Int? = nil
        ) {
            self.codec = codec
            self.frameRate = frameRate
            self.bitRate = bitRate
            self.bitRateMultiplier = bitRateMultiplier
            self.fileType = fileType
            self.includeAudio = includeAudio
            self.maxLongestEdge = maxLongestEdge
        }
    }

    /// What a render produced.
    public struct Output: Sendable, Hashable {
        public let fileURL: URL
        public let pixelSize: CGSize
        public let duration: TimeInterval
        public let frameCount: Int

        public init(fileURL: URL, pixelSize: CGSize, duration: TimeInterval, frameCount: Int) {
            self.fileURL = fileURL
            self.pixelSize = pixelSize
            self.duration = duration
            self.frameCount = frameCount
        }
    }

    // MARK: - Rendering

    /// Renders `edit` over `session`'s footage into `destination`.
    ///
    /// - Parameter progress: called with 0…1 as frames are written. Called from the render's
    ///   own context, so a caller that wants it on the main actor has to hop.
    @discardableResult
    public func render(
        session: RecordingSession,
        edit: StudioEdit,
        to destination: URL,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Output {
        let document = SessionDocument(session: session)
        let manifest = document.manifest()
        let source = Source(
            screen: session.screenURL,
            camera: FileManager.default.fileExists(atPath: session.cameraURL.path) ? session.cameraURL : nil,
            telemetry: document.telemetry() ?? InputTelemetry(),
            edit: edit,
            pixelSize: manifest?.pixelSize,
            cameraStartOffset: manifest?.cameraStartOffset ?? 0,
            pointPixelScale: manifest?.scale ?? 2,
            transcript: document.transcript() ?? Transcript(),
            soundtrack: session.soundtrackURL(for: edit),
            wallpaper: session.wallpaperURL(for: edit)
        )
        return try await render(
            source,
            to: destination,
            // The recording's own frame rate rather than the caller's: rendering 30 fps
            // footage at 60 writes every frame twice and doubles the file for nothing.
            options: manifest.map {
                Options(
                    codec: options.codec,
                    frameRate: $0.frameRate,
                    bitRate: options.bitRate,
                    bitRateMultiplier: options.bitRateMultiplier,
                    fileType: options.fileType,
                    includeAudio: options.includeAudio,
                    maxLongestEdge: options.maxLongestEdge
                )
            } ?? options,
            progress: progress
        )
    }

    /// Everything a render needs that is not about where the file goes.
    ///
    /// Bundled rather than passed as seven arguments: the footage, the telemetry and the
    /// edit are one recording described three ways, and a call site that can pass the
    /// screen of one session with the telemetry of another is a call site that eventually
    /// will.
    public struct Source: Sendable {
        public var screen: URL
        public var camera: URL?
        public var telemetry: InputTelemetry
        public var edit: StudioEdit
        /// The recording's pixel size, from its manifest. Read off the track when absent.
        public var pixelSize: CGSize?
        /// How far into the recording the camera's first frame landed (docs/10 R0.5).
        public var cameraStartOffset: TimeInterval
        /// Recorded pixels per point, for drawing the cursor at its real size
        /// (docs/11 S0.5).
        public var pointPixelScale: CGFloat
        public var transcript: Transcript
        /// Imported soundtrack that replaces the recording's own audio, when present.
        public var soundtrack: URL?
        /// Imported canvas wallpaper, when present.
        public var wallpaper: URL?

        public init(
            screen: URL,
            camera: URL? = nil,
            telemetry: InputTelemetry = InputTelemetry(),
            edit: StudioEdit,
            pixelSize: CGSize? = nil,
            cameraStartOffset: TimeInterval = 0,
            pointPixelScale: CGFloat = 2,
            transcript: Transcript = Transcript(),
            soundtrack: URL? = nil,
            wallpaper: URL? = nil
        ) {
            self.screen = screen
            self.camera = camera
            self.telemetry = telemetry
            self.edit = edit
            self.pixelSize = pixelSize
            self.cameraStartOffset = cameraStartOffset
            self.pointPixelScale = pointPixelScale
            self.transcript = transcript
            self.soundtrack = soundtrack
            self.wallpaper = wallpaper
        }
    }

    /// The same, with the pieces given directly rather than read from a session.
    @discardableResult
    public func render(
        _ source: Source,
        to destination: URL,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Output {
        let edit = source.edit
        let state = try await Preparation(
            screen: source.screen,
            camera: source.camera,
            edit: edit,
            sourceSize: source.pixelSize,
            options: options,
            cameraStartOffset: source.cameraStartOffset,
            soundtrack: source.soundtrack
        ).resolve()

        let plan = StudioRenderPlan(
            edit: edit,
            sourceSize: state.sourceSize,
            maxLongestEdge: options.maxLongestEdge,
            pointer: source.telemetry.rebased(to: edit.clips).pointer
        )
        let composer = StudioFrameComposer(
            plan: plan,
            edit: edit,
            telemetry: source.telemetry,
            transcript: source.transcript,
            frameRate: options.frameRate,
            pointPixelScale: source.pointPixelScale,
            wallpaper: source.wallpaper.flatMap { StudioWallpaper.image(at: $0) }
        )

        let interval = Self.signposter.beginInterval("studio.render")
        defer { Self.signposter.endInterval("studio.render", interval) }

        return try await write(
            state,
            composer: composer,
            destination: destination,
            options: options,
            progress: progress
        )
    }

    // MARK: - Preparation

    /// Everything that has to be loaded before a frame can be written.
    ///
    /// Its own type because resolving it is four `await`s that each have a reason to fail,
    /// and threading those through the render loop's error handling made the loop
    /// unreadable.
    struct Preparation {
        let screen: URL
        let camera: URL?
        let edit: StudioEdit
        let sourceSize: CGSize?
        let options: Options
        let cameraStartOffset: TimeInterval
        let soundtrack: URL?

        func resolve() async throws -> RenderState {
            let composition = try await build()
            guard let video = try? await composition.loadTracks(withMediaType: .video).first else {
                throw RenderError.noVideoTrack
            }
            let size = try await resolveSize(video)
            let tracks = try await composition.loadTracks(withMediaType: .video)
            return try await RenderState(
                composition: composition,
                screenTrack: video,
                // The builder appends the camera as the second video track, so the second
                // one is the camera or there is not one.
                cameraTrack: tracks.count > 1 ? tracks[1] : nil,
                audioTrack: try? composition.loadTracks(withMediaType: .audio).first,
                sourceSize: size,
                duration: CMTimeGetSeconds(composition.load(.duration))
            )
        }

        private func build() async throws -> AVMutableComposition {
            do {
                return try await ClipCompositionBuilder().composition(
                    for: edit.clips,
                    screen: screen,
                    camera: camera,
                    cameraStartOffset: cameraStartOffset,
                    soundtrack: soundtrack
                )
            } catch {
                throw RenderError.noVideoTrack
            }
        }

        /// The recording's pixel size, preferring the manifest.
        ///
        /// The manifest is authoritative because a track's `naturalSize` ignores its
        /// preferred transform, and a recording that was rotated would otherwise be
        /// planned against a frame with its width and height the wrong way round.
        private func resolveSize(_ track: AVAssetTrack) async throws -> CGSize {
            if let sourceSize, sourceSize.width > 0, sourceSize.height > 0 {
                return sourceSize
            }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let applied = natural.applying(transform)
            let size = CGSize(width: abs(applied.width), height: abs(applied.height))
            guard size.width > 0, size.height > 0 else { throw RenderError.noVideoTrack }
            return size
        }
    }

    /// The loaded composition and its tracks.
    struct RenderState {
        let composition: AVMutableComposition
        let screenTrack: AVAssetTrack
        let cameraTrack: AVAssetTrack?
        let audioTrack: AVAssetTrack?
        let sourceSize: CGSize
        let duration: TimeInterval
    }
}
