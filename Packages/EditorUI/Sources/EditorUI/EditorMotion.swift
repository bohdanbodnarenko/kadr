import AppKit
import ControlKit
import SwiftUI

/// Editor/studio motion and material policy (docs/14 UX-03, UX-30C).
///
/// Reads ControlKit's tokens, which the agent shares, instead of keeping a hand copy of
/// the agent's policy (docs/18 X-1).
enum EditorMotion {
    static let rtlArgument = "-KadrRTL"

    static var reduceMotion: Bool {
        KadrAccessibility.reduceMotion
    }

    static var reduceTransparency: Bool {
        KadrAccessibility.reduceTransparency
    }

    static var increaseContrast: Bool {
        KadrAccessibility.increaseContrast
    }

    static var differentiateWithoutColor: Bool {
        KadrAccessibility.differentiateWithoutColor
    }

    static var isRightToLeft: Bool {
        ProcessInfo.processInfo.arguments.contains(rtlArgument)
    }

    static func animation(_ animation: Animation) -> Animation? {
        KadrMotion.animation(animation)
    }

    static func transition(_ transition: AnyTransition) -> AnyTransition {
        KadrMotion.transition(transition)
    }
}

extension View {
    func editorAnimation(_ animation: Animation, value: some Equatable) -> some View {
        self.animation(EditorMotion.animation(animation), value: value)
    }

    /// Process-local RTL override (`-KadrRTL`). Public so the editor Help window can match.
    public func editorLayoutDirection() -> some View {
        environment(\.layoutDirection, EditorMotion.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
