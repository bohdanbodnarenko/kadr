import AnnotationModel
import AppKit
import StudioSession
import SwiftUI

extension Color {
    init(_ colour: StudioColor) {
        self.init(.sRGB, red: colour.red, green: colour.green, blue: colour.blue)
    }
}

extension StudioColor {
    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent)
        )
    }

    init(_ colour: AnnotationColor) {
        self.init(red: colour.red, green: colour.green, blue: colour.blue)
    }
}
