import AppKit
import SwiftUI

// One design-token set for the agent and the editor (docs/18 X-1).
//
// Both apps link ControlKit, so the type ramp, radii, spacing, motion and chrome fills live
// here once instead of as 74 font-size literals, 13 corner radii and 79 hand-tuned opacity
// fills. The fills read the system's accessibility settings, which is how Increase Contrast
// and Reduce Transparency reach every surface that uses them (docs/18 X-3).

/// The system accessibility display settings, read on demand so a change in System Settings
/// applies at the next redraw without a timer.
public enum KadrAccessibility {
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    public static var differentiateWithoutColor: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }
}

/// The type ramp. Nothing in Kadr's chrome is set smaller than `micro`.
public enum KadrType {
    public static let micro: CGFloat = 10
    public static let caption: CGFloat = 11
    public static let body: CGFloat = 12
    public static let title: CGFloat = 13

    public static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: max(size, micro), weight: weight)
    }

    /// The same size with tabular figures, for values that change while being read.
    public static func numeric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        font(size, weight: weight).monospacedDigit()
    }
}

/// Corner radii.
public enum KadrRadius {
    public static let small: CGFloat = 4
    public static let medium: CGFloat = 6
    public static let large: CGFloat = 8
    public static let panel: CGFloat = 12
}

/// Spacing steps.
public enum KadrSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 8
    public static let large: CGFloat = 12
    public static let xl: CGFloat = 16
}

/// Motion. Critically damped springs only: chrome responds, it does not bounce.
public enum KadrMotion {
    /// Hover highlights and small reveals.
    public static let hover = Animation.easeOut(duration: 0.12)
    /// A control changing state.
    public static let state = Animation.spring(duration: 0.24, bounce: 0)
    /// Something moving or resizing.
    public static let layout = Animation.spring(duration: 0.32, bounce: 0)
    /// A button or row answering the pointer: hover, press.
    public static let press = Animation.snappy(duration: 0.12)
    /// A small piece of chrome appearing or switching: a toast, a section, a crop bar.
    public static let snap = Animation.snappy(duration: 0.2)
    /// A panel or stack settling into a new arrangement.
    public static let settle = Animation.smooth(duration: 0.3, extraBounce: 0)
    /// A bar changing mode, with the slight give that tells the eye it moved.
    public static let panel = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// What replaces motion under Reduce Motion: a short fade.
    public static let reduced = Animation.easeOut(duration: 0.12)

    /// `animation`, or nothing under Reduce Motion.
    public static func animation(_ animation: Animation) -> Animation? {
        KadrAccessibility.reduceMotion ? nil : animation
    }

    /// `transition`, or a plain fade under Reduce Motion.
    public static func transition(_ transition: AnyTransition) -> AnyTransition {
        KadrAccessibility.reduceMotion ? .opacity : transition
    }
}

/// Chrome fills that adapt to Increase Contrast.
///
/// Each is `.primary` at an opacity, so it reads in light and dark alike; the opacities are
/// raised under Increase Contrast rather than switched to a second palette.
public enum KadrFill {
    public enum Role: CaseIterable, Sendable {
        case hover
        case selected
        case stroke
        case scrim
    }

    /// The opacity a role uses, as a pure function so it can be tested.
    public static func opacity(_ role: Role, increaseContrast: Bool) -> Double {
        switch role {
        case .hover: increaseContrast ? 0.16 : 0.07
        case .selected: increaseContrast ? 0.24 : 0.12
        case .stroke: increaseContrast ? 0.45 : 0.14
        case .scrim: increaseContrast ? 0.6 : 0.35
        }
    }

    public static func color(_ role: Role) -> Color {
        let base: Color = role == .scrim ? .black : .primary
        return base.opacity(opacity(role, increaseContrast: KadrAccessibility.increaseContrast))
    }

    public static var hover: Color {
        color(.hover)
    }

    public static var selected: Color {
        color(.selected)
    }

    public static var stroke: Color {
        color(.stroke)
    }

    public static var scrim: Color {
        color(.scrim)
    }

    /// A hairline's width: thicker under Increase Contrast.
    public static var strokeWidth: CGFloat {
        KadrAccessibility.increaseContrast ? 1.5 : 1
    }
}

/// Shadows. Four depths instead of 19 hand-tuned ones, so chrome at the same height casts the
/// same shadow everywhere.
public enum KadrShadow: Sendable {
    /// Keeps a white glyph legible over a picture.
    case glyph
    /// A banner or a button floating over content.
    case banner
    /// A popover-like panel inside a window.
    case raised
    /// A panel floating over other apps: cards, the peek tab, the island. A wide soft shadow
    /// for depth plus a tight one that defines the edge.
    case floating
}

private struct KadrShadowModifier: ViewModifier {
    let shadow: KadrShadow

    func body(content: Content) -> some View {
        switch shadow {
        case .glyph:
            content.shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        case .banner:
            content.shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        case .raised:
            content.shadow(color: .black.opacity(0.16), radius: 13, y: 4)
        case .floating:
            content
                .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

public extension View {
    /// One of the shared shadow depths (docs/18 X-1).
    func kadrShadow(_ shadow: KadrShadow) -> some View {
        modifier(KadrShadowModifier(shadow: shadow))
    }
}
