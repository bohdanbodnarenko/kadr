import AVFoundation
import Foundation
import MediaExport
import StudioRender
import UniformTypeIdentifiers

/// How a studio export is encoded, asked at the moment of export rather than parked in
/// an inspector section nobody opens.
///
/// Confirming remembers the choice, so the next recording starts from what the user
/// picked last instead of the factory defaults.
public struct StudioExportSettings: Sendable, Hashable, Codable {
    public enum Quality: String, CaseIterable, Sendable, Codable, Identifiable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"

        public var id: String {
            rawValue
        }

        var bitRateMultiplier: Double {
            switch self {
            case .high: 1
            case .medium: 0.55
            case .low: 0.3
            }
        }

        /// The encoder quality a compressed export aims for.
        ///
        /// Chosen by measurement on a 1080p60 code clip against the uncompressed High
        /// export: High is visually identical at about a quarter smaller, Medium within a
        /// decibel at about 40% smaller, Low half the size with slightly softer text.
        /// Below 0.6 the loss became visible, so nothing here goes lower.
        var targetQuality: Double {
            switch self {
            case .high: 0.8
            case .medium: 0.7
            case .low: 0.6
            }
        }
    }

    public enum Codec: String, CaseIterable, Sendable, Codable, Identifiable {
        case hevc = "HEVC"
        case h264 = "H.264"

        public var id: String {
            rawValue
        }

        var videoCodec: AVVideoCodecType {
            switch self {
            case .hevc: .hevc
            case .h264: .h264
            }
        }
    }

    public enum Resolution: String, CaseIterable, Sendable, Codable, Identifiable {
        case original = "Original"
        case fullHD = "1080p"
        case hd = "720p"
        case sd = "480p"

        public var id: String {
            rawValue
        }

        var maxLongestEdge: Int? {
            switch self {
            case .original: nil
            case .fullHD: 1920
            case .hd: 1280
            case .sd: 854
            }
        }
    }

    public enum Container: String, CaseIterable, Sendable, Codable, Identifiable {
        case mov = "MOV"
        case mp4 = "MP4"
        case gif = "GIF"

        public var id: String {
            rawValue
        }

        var fileType: AVFileType {
            switch self {
            case .mov, .gif: .mov
            case .mp4: .mp4
            }
        }

        public var utType: UTType {
            switch self {
            case .mov: .quickTimeMovie
            case .mp4: .mpeg4Movie
            case .gif: .gif
            }
        }

        public var filenameExtension: String {
            rawValue.lowercased()
        }
    }

    public var quality: Quality
    public var codec: Codec
    public var resolution: Resolution
    public var container: Container
    public var includeAudio: Bool
    public var frameRate: FrameRate
    /// Encode to a quality rather than a bit rate: a smaller file that looks the same,
    /// because the still parts of a screen recording stop costing anything.
    public var compresses: Bool

    public enum FrameRate: String, CaseIterable, Sendable, Codable, Identifiable {
        case source = "Source"
        case thirty = "30"
        case sixty = "60"

        public var id: String {
            rawValue
        }

        public var title: String {
            rawValue
        }

        func applied(to manifest: Int) -> Int {
            switch self {
            case .source: max(manifest, 1)
            case .thirty: min(30, max(manifest, 1))
            case .sixty: min(60, max(manifest, 1))
            }
        }
    }

    public init(
        quality: Quality = .high,
        codec: Codec = .hevc,
        resolution: Resolution = .original,
        container: Container = .mov,
        includeAudio: Bool = true,
        frameRate: FrameRate = .source,
        compresses: Bool = false
    ) {
        self.quality = quality
        self.codec = codec
        self.resolution = resolution
        self.container = container
        self.includeAudio = includeAudio
        self.frameRate = frameRate
        self.compresses = compresses
    }

    private enum CodingKeys: String, CodingKey {
        case quality, codec, resolution, container, includeAudio, frameRate, compresses
    }

    /// Decodes a choice remembered before `compresses` existed, rather than throwing it
    /// all away and starting over from the factory defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decode(Quality.self, forKey: .quality)
        codec = try container.decode(Codec.self, forKey: .codec)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        self.container = try container.decode(Container.self, forKey: .container)
        includeAudio = try container.decode(Bool.self, forKey: .includeAudio)
        frameRate = try container.decodeIfPresent(FrameRate.self, forKey: .frameRate) ?? .source
        compresses = try container.decodeIfPresent(Bool.self, forKey: .compresses) ?? false
    }

    /// Whether this export will actually use the quality target. A GIF is re-encoded by
    /// ImageIO afterwards, so its intermediate movie keeps the plain settings.
    public var usesCompression: Bool {
        compresses && container != .gif
    }

    public func rendererOptions(manifestFrameRate: Int = 60) -> StudioRenderer.Options {
        StudioRenderer.Options(
            codec: container == .gif ? .h264 : codec.videoCodec,
            // A GIF samples its intermediate movie at its own rate, so rendering that movie
            // at 60 fps was four times the frames for nothing (docs/17 T-STU-3).
            frameRate: container == .gif
                ? min(gifOptions.frameRate, max(manifestFrameRate, 1))
                : frameRate.applied(to: manifestFrameRate),
            bitRateMultiplier: quality.bitRateMultiplier,
            fileType: container == .gif ? .mov : container.fileType,
            includeAudio: container == .gif ? false : includeAudio,
            maxLongestEdge: maxLongestEdge,
            targetQuality: usesCompression ? quality.targetQuality : nil,
            // 96 kb/s AAC is transparent for narration; the default 128 stays otherwise.
            audioBitRate: usesCompression ? 96000 : nil
        )
    }

    public var rendererOptions: StudioRenderer.Options {
        rendererOptions()
    }

    public var utType: UTType {
        container.utType
    }

    public var filenameExtension: String {
        container.filenameExtension
    }

    public var maxLongestEdge: Int? {
        if container == .gif {
            return gifOptions.maximumWidth
        }
        return resolution.maxLongestEdge
    }

    /// How the GIF pass is encoded after the movie render (docs/03 §1.8).
    var gifOptions: GIFOptions {
        let width = switch resolution {
        case .original, .fullHD: 800
        case .hd: 720
        case .sd: 480
        }
        let fps = switch quality {
        case .high: 15
        case .medium: 10
        case .low: 8
        }
        return GIFOptions(frameRate: fps, maximumWidth: width)
    }

    /// Roughly how large an uncompressed export of `duration` seconds at `size` will be.
    ///
    /// The bit-rate target is what the encoder aims for, so this is close for a plain
    /// export. A compressed one has no fixed rate; the dialog says "smaller than this"
    /// rather than inventing a number.
    func estimatedBytes(outputSize size: CGSize, duration: TimeInterval, manifestFrameRate: Int) -> Int? {
        guard container != .gif, duration > 0, size.width > 0, size.height > 0 else { return nil }
        let options = rendererOptions(manifestFrameRate: manifestFrameRate)
        let video = Double(StudioRenderer.bitRate(for: size, frameRate: options.frameRate))
            * quality.bitRateMultiplier
        let audio = options.includeAudio ? Double(options.audioChannelCount == 1 ? 96000 : 128_000) : 0
        return Int((video + audio) * duration / 8)
    }

    /// Last confirmed choice, or the defaults if none has been saved yet.
    public static var remembered: StudioExportSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode(StudioExportSettings.self, from: data)
            else {
                return StudioExportSettings()
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static let defaultsKey = "studioExportSettings"
}
