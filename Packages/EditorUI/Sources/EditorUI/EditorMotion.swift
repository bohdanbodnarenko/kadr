import AppKit
import SwiftUI

/// Editor/studio motion and material policy (docs/14 UX-03, UX-30C).
///
/// Process-local: EditorUI must not push SwiftUI into Shared.
enum EditorMotion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func animation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func transition(_ transition: AnyTransition) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}

extension View {
    func editorAnimation(_ animation: Animation, value: some Equatable) -> some View {
        self.animation(EditorMotion.animation(animation), value: value)
    }
}
