import AnnotationModel
import AppKit
import SwiftUI

extension Color {
    init(_ colour: AnnotationColor) {
        self.init(.sRGB, red: colour.red, green: colour.green, blue: colour.blue, opacity: colour.alpha)
    }
}

extension AnnotationColor {
    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .red
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }
}
