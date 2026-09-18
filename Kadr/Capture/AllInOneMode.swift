import Foundation
import Shared

/// What the All-in-One strip can start (docs/03 §1.4).
nonisolated enum AllInOneMode: String, CaseIterable, Sendable {
    case area
    case window
    case screen
    case record
    case gif
    case scrolling
    case ocr
    case color

    var title: String {
        switch self {
        case .area: KadrText.string("Area")
        case .window: KadrText.string("Window")
        case .screen: KadrText.string("Screen")
        case .record: KadrText.string("Record")
        case .gif: KadrText.string("GIF")
        case .scrolling: KadrText.string("Scrolling")
        case .ocr: KadrText.string("Text")
        case .color: KadrText.string("Colour")
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "menubar.rectangle"
        case .record: "record.circle"
        case .gif: "square.stack"
        case .scrolling: "arrow.up.and.down"
        case .ocr: "text.viewfinder"
        case .color: "eyedropper"
        }
    }

    var help: String {
        switch self {
        case .area: KadrText.string("Drag to capture a region")
        case .window: KadrText.string("Click a window to capture it")
        case .screen: KadrText.string("Capture the whole display")
        case .record: KadrText.string("Open the recorder")
        case .gif: KadrText.string("Record a region, then export a GIF")
        case .scrolling: KadrText.string("Capture a scrolling region")
        case .ocr: KadrText.string("Select text and copy it")
        case .color: KadrText.string("Pick a colour from the screen")
        }
    }

    /// Single-key shortcut while the HUD is key (CleanShot 4.8).
    var shortcut: Character {
        switch self {
        case .area: "a"
        case .window: "w"
        case .screen: "f"
        case .record: "r"
        case .gif: "g"
        case .scrolling: "s"
        case .ocr: "t"
        case .color: "p"
        }
    }

    static func matching(shortcut raw: String) -> AllInOneMode? {
        guard let character = raw.lowercased().first else { return nil }
        return allCases.first { $0.shortcut == character }
    }
}
