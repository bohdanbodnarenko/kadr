import CoreGraphics
import Foundation
import HistoryKit

/// One pinned screenshot, remembered across launches (docs/03 §4 P2).
struct PinRecord: Codable, Equatable, Sendable {
    var path: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var alpha: Double
    var clickThrough: Bool

    init(
        path: String,
        frame: CGRect,
        alpha: Double,
        clickThrough: Bool
    ) {
        self.path = path
        x = frame.origin.x
        y = frame.origin.y
        width = frame.width
        height = frame.height
        self.alpha = alpha
        self.clickThrough = clickThrough
    }

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// JSON list of open pins in Application Support.
struct PinStore: Sendable {
    var fileURL: URL

    static func applicationSupport() -> PinStore? {
        guard let root = try? HistoryLayout.applicationSupport().root else { return nil }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return PinStore(fileURL: root.appendingPathComponent("pins.json"))
    }

    var hasRecords: Bool {
        !load().isEmpty
    }

    func load() -> [PinRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([PinRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    func save(_ records: [PinRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
