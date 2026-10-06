import AVFoundation
import CoreGraphics

/// The colour space an export is written in (docs/18 Phase 4).
///
/// Every frame used to be rendered and tagged as sRGB, so a recording of a wide-colour
/// display lost its saturated reds and greens on the way out. Display P3 keeps them: frames
/// are drawn into a P3 buffer and the movie is tagged with P3 primaries, which every
/// current Apple player honours. Eight bits and the Rec. 709 transfer either way — this is
/// wider colour, not HDR.
public enum StudioColorSpace: String, Sendable, Codable, CaseIterable {
    case sRGB
    case displayP3

    /// The space frames are rendered into.
    public var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: StudioRenderContext.sRGB
        case .displayP3: Self.p3Space
        }
    }

    /// How the movie's video track is tagged. Always tagged, BT.709 transfer and matrix
    /// (docs/17 T-STU-12): untagged, QuickTime, browsers and Slack each guessed differently.
    var writerColorProperties: [String: String] {
        [
            AVVideoColorPrimariesKey: self == .displayP3
                ? AVVideoColorPrimaries_P3_D65
                : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    private static let p3Space: CGColorSpace = .init(name: CGColorSpace.displayP3) ?? StudioRenderContext.sRGB
}
