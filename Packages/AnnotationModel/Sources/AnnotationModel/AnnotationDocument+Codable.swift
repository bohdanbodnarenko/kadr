import Foundation

public extension AnnotationDocument {
    enum CodingKeys: String, CodingKey {
        case baseImage
        case history
        case historyIndex
        case selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedBase = try container.decode(BaseImageReference.self, forKey: .baseImage)
        let decodedOrientation = decodedBase.orientation
        decodedBase.orientation = .identity
        baseImage = decodedBase
        history = try container.decode([[AnnotationCommand]].self, forKey: .history)
        historyIndex = try container.decode(Int.self, forKey: .historyIndex)
        selection = try container.decodeIfPresent(Set<AnnotationID>.self, forKey: .selection) ?? []
        let count = max(history.count, 1)
        var frames = Array(repeating: CanvasOrientation.identity, count: count)
        let index = min(max(historyIndex, 0), count - 1)
        frames[index] = decodedOrientation
        orientationHistory = frames
        gestureBaseline = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var encodedBase = baseImage
        encodedBase.orientation = orientationHistory[historyIndex]
        try container.encode(encodedBase, forKey: .baseImage)
        try container.encode(history, forKey: .history)
        try container.encode(historyIndex, forKey: .historyIndex)
        try container.encode(selection, forKey: .selection)
    }
}
