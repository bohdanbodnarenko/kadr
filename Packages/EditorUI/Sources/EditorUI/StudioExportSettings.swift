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

    /// How wide a GIF is. GIF's own choice, because the movie resolutions do not apply:
    /// "Original" used to mean 800 px (docs/17 T-STU-7).
    public enum GIFWidth: Int, CaseIterable, Sendable, Codable, Identifiable {
        case large = 800
        case medium = 640
        case small = 480

        public var id: Int {
            rawValue
        }

        public var title: String {
            "\(rawValue) px"
        }
    }

    /// A GIF's frame rate, its own for the same reason.
    public enum GIFFrameRate: Int, CaseIterable, Sendable, Codable, Identifiable {
        case smooth = 15
        case standard = 10
        case light = 8

        public var id: Int {
            rawValue
        }

        public var title: String {
            "\(rawValue) fps"
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
    public var gifWidth: GIFWidth
    public var gifFrameRate: GIFFrameRate

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
        // H.264 by default (docs/17 T-STU-10): an MP4 promises to play on Windows, in
        // browsers and in Slack, and an HEVC one often does not.
        codec: Codec = .h264,
        resolution: Resolution = .original,
        container: Container = .mov,
        includeAudio: Bool = true,
        frameRate: FrameRate = .source,
        compresses: Bool = false,
        gifWidth: GIFWidth = .large,
        gifFrameRate: GIFFrameRate = .smooth
    ) {
        self.quality = quality
        self.codec = codec
        self.resolution = resolution
        self.container = container
        self.includeAudio = includeAudio
        self.frameRate = frameRate
        self.compresses = compresses
        self.gifWidth = gifWidth
        self.gifFrameRate = gifFrameRate
    }

    private enum CodingKeys: String, CodingKey {
        case quality, codec, resolution, container, includeAudio, frameRate, compresses
        case gifWidth, gifFrameRate
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
        gifWidth = try container.decodeIfPresent(GIFWidth.self, forKey: .gifWidth) ?? .large
        gifFrameRate = try container.decodeIfPresent(GIFFrameRate.self, forKey: .gifFrameRate) ?? .smooth
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
        guard codec == .h264 else { return resolution.maxLongestEdge }
        // Clamped, not refused (docs/17 T-STU-10): Apple's H.264 encoder fails above
        // 4096 px, so "Original" on a 5K display was an export that could not finish.
        return min(resolution.maxLongestEdge ?? Self.h264MaximumEdge, Self.h264MaximumEdge)
    }

    /// The longest edge the H.264 hardware encoder accepts.
    public static let h264MaximumEdge = 4096

    /// How the GIF pass is encoded after the movie render (docs/03 §1.8).
    var gifOptions: GIFOptions {
        GIFOptions(frameRate: gifFrameRate.rawValue, maximumWidth: gifWidth.rawValue)
    }

    /// What the GIF encode will really do to a `duration`-second edit at `size`
    /// (docs/17 T-STU-7). The encoder plans the same way from the rendered movie, so the
    /// popover can say "10 fps, 640 px, first 90 s" before anything is rendered.
    func gifPlan(outputSize size: CGSize, duration: TimeInterval) -> GIFPlan {
        GIFPlan.fitting(sourceSeconds: duration, frameSize: size, options: gifOptions)
    }

    /// Roughly how large an uncompressed export of `duration` seconds at `size` will be.
    ///
    /// The bit-rate target is what the encoder aims for, so this is close for a plain
    /// export. A compressed one has no fixed rate; the dialog says "smaller than this"
    /// rather than inventing a number.
    func estimatedBytes(outputSize size: CGSize, duration: TimeInterval, manifestFrameRate: Int) -> Int? {
        guard duration > 0, size.width > 0, size.height > 0 else { return nil }
        if container == .gif {
            return Self.estimatedGIFBytes(plan: gifPlan(outputSize: size, duration: duration), aspect: size)
        }
        let options = rendererOptions(manifestFrameRate: manifestFrameRate)
        let video = Double(StudioRenderer.bitRate(for: size, frameRate: options.frameRate))
            * quality.bitRateMultiplier
        let audio = options.includeAudio ? Double(options.audioChannelCount == 1 ? 96000 : 128_000) : 0
        return Int((video + audio) * duration / 8)
    }

    /// A GIF's size from its plan: frames × pixels × what an LZW-coded screen frame
    /// usually costs per pixel. Rough — GIF size depends on how much changes — but it
    /// is the "size estimate before export" docs/03 §1.8 asks for, which GIF had none of.
    static func estimatedGIFBytes(plan: GIFPlan, aspect size: CGSize) -> Int {
        let width = Double(min(CGFloat(plan.maximumWidth), size.width))
        let height = size.width > 0 ? width * Double(size.height / size.width) : width
        return Int(Double(plan.frameCount) * width * height * gifBytesPerPixel)
    }

    /// An assumption, not a measurement: screen recordings are mostly flat colour and most
    /// of each frame repeats the last one, so they code far below a byte a pixel.
    static let gifBytesPerPixel = 0.12

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
