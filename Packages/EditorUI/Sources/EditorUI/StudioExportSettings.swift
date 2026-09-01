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

    public init(
        quality: Quality = .high,
        codec: Codec = .hevc,
        resolution: Resolution = .original,
        container: Container = .mov,
        includeAudio: Bool = true
    ) {
        self.quality = quality
        self.codec = codec
        self.resolution = resolution
        self.container = container
        self.includeAudio = includeAudio
    }

    public var rendererOptions: StudioRenderer.Options {
        StudioRenderer.Options(
            codec: container == .gif ? .h264 : codec.videoCodec,
            bitRateMultiplier: quality.bitRateMultiplier,
            fileType: container == .gif ? .mov : container.fileType,
            includeAudio: container == .gif ? false : includeAudio,
            maxLongestEdge: maxLongestEdge
        )
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
