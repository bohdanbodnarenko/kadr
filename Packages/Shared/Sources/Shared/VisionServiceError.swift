import Foundation

/// Errors the helper can report back.
public enum VisionServiceError: Int, Error, Sendable, Codable {
    case couldNotDecodeImage = 1
    case recognitionFailed = 2
    case invalidRequest = 3
    case stitchFailed = 4
    case notEnoughFrames = 5
    case historyUnavailable = 6
    case noSubjectFound = 7
    case maskFailed = 8
    /// The capture could not be re-encoded smaller (docs/09 U2.4).
    case compressionFailed = 9
    case transcriptionFailed = 10
    case speechUnavailable = 11
    case insufficientDiskSpace = 12

    public var localizedDescription: String {
        switch self {
        case .couldNotDecodeImage: "Kadr could not read the captured image."
        case .recognitionFailed: "Text recognition failed."
        case .invalidRequest: "The text recognition request was malformed."
        case .stitchFailed: "Kadr could not stitch the scrolling capture."
        case .notEnoughFrames: "A scrolling capture needs at least two frames."
        case .historyUnavailable: "Kadr could not open the capture library."
        case .noSubjectFound: "Kadr could not find a subject in this capture."
        case .compressionFailed: "Kadr could not compress this capture."
        case .maskFailed: "Kadr could not separate the subject from the background."
        case .transcriptionFailed: "Kadr could not transcribe this recording."
        case .speechUnavailable: "Speech recognition is not available on this Mac."
        case .insufficientDiskSpace: "There is not enough free space to download the speech model."
        }
    }
}
