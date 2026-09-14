import AppKit
import SwiftUI

/// Process-local accessibility policies for the agent (docs/14 UX-03).
///
/// Kept out of Shared: that package cannot take SwiftUI, and these values are only
/// meaningful next to windows and chrome. Read on demand so a toggle in System Settings
/// is honoured without a timer.
enum AccessibilityChrome {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Critically damped spring: no decorative bounce (docs/14 §8).
    static var defaultSpring: Animation {
        .spring(duration: 0.32, bounce: 0)
    }

    /// Short opacity-only change used when Reduce Motion is on.
    static var reduced: Animation {
        .easeOut(duration: 0.12)
    }

    static func animation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func transition(_ transition: AnyTransition) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}

/// Applies Reduce Motion, Reduce Transparency, and Increase Contrast to custom chrome.
struct AccessibilityChromeModifier: ViewModifier {
    var material: Material = .regularMaterial
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if AccessibilityChrome.reduceTransparency {
                content
                    .background(.background, in: shape)
            } else {
                content
                    .background(material, in: shape)
            }
        }
        .overlay {
            if AccessibilityChrome.increaseContrast || AccessibilityChrome.reduceTransparency {
                shape.strokeBorder(Color.primary.opacity(AccessibilityChrome.increaseContrast ? 0.45 : 0.18))
            }
        }
    }
}

extension View {
    /// Interruptible motion that becomes a no-op under Reduce Motion.
    func kadrAnimation(_ animation: Animation, value: some Equatable) -> some View {
        self.animation(AccessibilityChrome.animation(animation), value: value)
    }

    func kadrChrome(material: Material = .regularMaterial, cornerRadius: CGFloat = 10) -> some View {
        modifier(AccessibilityChromeModifier(material: material, cornerRadius: cornerRadius))
    }

    /// Absolute minimum hit target (docs/14 §8). Visual size is unchanged.
    func kadrHitTarget(minSize: CGFloat = 20) -> some View {
        frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}
