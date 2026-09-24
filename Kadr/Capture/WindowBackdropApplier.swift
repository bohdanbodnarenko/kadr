import AnnotationModel
import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import ImageIO
import MediaExport
import SettingsKit
import Shared

/// Composites a window capture onto the user's chosen backdrop (docs/03 §1.2).
///
/// The overlay shows the flattened result. A sibling `.kadr` keeps the original window
/// plus beautify chrome, so the editor can still change the fill.
enum WindowBackdropApplier {
    static func apply(_ capture: Capture, settings: AppSettings) -> Capture {
        guard let fill = fill(for: capture, settings: settings) else { return capture }
        let padding = Int((CGFloat(settings.windowBackdropPadding) * capture.metadata.scale.factor).rounded())
        guard let composited = WindowBackdropCompositor.composite(
            capture.image,
            onto: fill,
            padding: padding
        ) else {
            return capture
        }
        return capture.replacingImage(composited)
    }

    /// The beautify chrome that reconstructs this backdrop in the editor, or `nil` when
    /// the window is left transparent.
    static func beautifySpec(settings: AppSettings, displayID: CGDirectDisplayID?) -> BeautifySpec? {
        guard !settings.transparentWindowBackground else { return nil }
        let padding = BeautifyMetric.points(CGFloat(settings.windowBackdropPadding))
        let backdrop: BeautifyBackdrop = switch settings.windowBackdrop {
        case .white: .solid(.white)
        case .black: .solid(.black)
        case .gray: .solid(AnnotationColor(red: 0.55, green: 0.55, blue: 0.55))
        case .desktop:
            wallpaperPath(for: displayID).map(BeautifyBackdrop.image)
                ?? .solid(AnnotationColor(red: 0.55, green: 0.55, blue: 0.55))
        case .custom:
            if settings.windowBackdropImagePath.isEmpty {
                .solid(AnnotationColor(red: 0.55, green: 0.55, blue: 0.55))
            } else {
                .image(path: settings.windowBackdropImagePath)
            }
        }
        return BeautifySpec(
            padding: padding,
            cornerRadius: .zero,
            backdrop: backdrop,
            shadow: .none,
            aspect: .original
        )
    }

    private static func fill(for capture: Capture, settings: AppSettings) -> WindowBackdropFill? {
        guard !settings.transparentWindowBackground else { return nil }
        let fill: WindowBackdropFill = switch settings.windowBackdrop {
        case .white: .color(red: 1, green: 1, blue: 1)
        case .black: .color(red: 0, green: 0, blue: 0)
        case .gray: .color(red: 0.55, green: 0.55, blue: 0.55)
        case .desktop:
            wallpaper(for: capture.metadata.displayID).map(WindowBackdropFill.image)
                ?? .color(red: 0.55, green: 0.55, blue: 0.55)
        case .custom:
            image(at: settings.windowBackdropImagePath).map(WindowBackdropFill.image)
                ?? .color(red: 0.55, green: 0.55, blue: 0.55)
        }
        return fill
    }

    private static func wallpaperPath(for displayID: CGDirectDisplayID?) -> String? {
        let screen = NSScreen.screens.first { screen in
            guard let displayID else { return false }
            return Self.displayID(of: screen) == displayID
        } ?? ActiveScreen.resolve()
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return url.path
    }

    private static func wallpaper(for displayID: CGDirectDisplayID?) -> CGImage? {
        wallpaperPath(for: displayID).flatMap(image(at:))
    }

    private static func image(at path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
