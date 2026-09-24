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

    /// Hover-revealed controls stay revealed for VoiceOver, which has no hover to reveal them.
    static var voiceOverEnabled: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
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

    /// Floating chrome: Liquid Glass on macOS 26, a richer material before that.
    ///
    /// Apple's rule is glass belongs on the navigation layer that sits *over*
    /// content — HUDs, toolbars, floating controls — never on the content itself.
    /// Reduce Transparency and Increase Contrast swap to an opaque fill + stroke.
    @ViewBuilder
    func kadrLiquidGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        if AccessibilityChrome.reduceTransparency {
            background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay {
                    shape.strokeBorder(
                        Color.primary.opacity(AccessibilityChrome.increaseContrast ? 0.45 : 0.18)
                    )
                }
        } else if #available(macOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background {
                shape.fill(.regularMaterial)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(0.32), radius: 22, y: 8)
            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        }
    }

    /// Absolute minimum hit target (docs/14 §8). Visual size is unchanged.
    func kadrHitTarget(minSize: CGFloat = 20) -> some View {
        frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }

    /// Launch `-KadrRTL` to force right-to-left even in English (docs/14 UX-01.4).
    ///
    /// Without the flag the system's direction is left alone: forcing `.leftToRight`
    /// turned every right-to-left user's Settings backwards (docs/17 T-SH-8).
    @ViewBuilder
    func kadrLayoutDirection() -> some View {
        if KadrText.isRightToLeft {
            environment(\.layoutDirection, .rightToLeft)
        } else {
            self
        }
    }
}
