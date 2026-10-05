import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os
import SettingsKit
import Shared
import UniformTypeIdentifiers

/// Reads and writes Finder / wallpaper state so tests can stand in for the real desktop.
@MainActor
protocol DesktopAppearanceApplying: AnyObject {
    var iconsVisible: Bool { get set }
    var widgetsHidden: Bool { get set }
    func currentWallpaperURLs() -> [CGDirectDisplayID: URL]
    func applyWallpaper(_ url: URL, screenID: CGDirectDisplayID)
    func restoreWallpapers(_ urls: [CGDirectDisplayID: URL])
    /// Undoes a Finder-restart hide an earlier build left behind (docs/18 SH-4).
    func restoreLegacyIconHide()
}

extension DesktopAppearanceApplying {
    func restoreLegacyIconHide() {}
}

/// A wallpaper cover over the icons, Window Manager widgets, and NSWorkspace wallpapers.
@MainActor
final class FinderDesktopAppearance: DesktopAppearanceApplying {
    private let logger = KadrLog.logger(.app)
    private let cover = DesktopCover()

    /// Icons are hidden by covering them, never by restarting the Finder (docs/18 SH-4).
    var iconsVisible: Bool {
        get { !cover.isShowing }
        set {
            if newValue {
                cover.hide()
            } else {
                cover.show()
            }
        }
    }

    /// Builds before docs/18 SH-4 hid icons with Finder's `CreateDesktop` and a restart. A
    /// crash in one of those left the desktop empty; put it back once, here, and never
    /// touch the Finder otherwise.
    func restoreLegacyIconHide() {
        let defaults = UserDefaults(suiteName: "com.apple.finder")
        guard defaults?.object(forKey: "CreateDesktop") != nil,
              defaults?.bool(forKey: "CreateDesktop") == false
        else { return }
        defaults?.removeObject(forKey: "CreateDesktop")
        defaults?.synchronize()
        relaunchFinder()
        logger.notice("Restored desktop icons hidden by an earlier build")
    }

    var widgetsHidden: Bool {
        get {
            let defaults = UserDefaults(suiteName: "com.apple.WindowManager")
            return (defaults?.object(forKey: "StandardHideWidgets") as? Int).map { $0 != 0 } ?? false
        }
        set {
            let defaults = UserDefaults(suiteName: "com.apple.WindowManager")
            defaults?.set(newValue ? 1 : 0, forKey: "StandardHideWidgets")
            defaults?.synchronize()
        }
    }

    func currentWallpaperURLs() -> [CGDirectDisplayID: URL] {
        var result: [CGDirectDisplayID: URL] = [:]
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen)
            else { continue }
            result[id] = url
        }
        return result
    }

    func applyWallpaper(_ url: URL, screenID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == screenID }) else { return }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            logger.error("Could not set wallpaper: \(error.localizedDescription, privacy: .public)")
        }
    }

    func restoreWallpapers(_ urls: [CGDirectDisplayID: URL]) {
        for (id, url) in urls {
            applyWallpaper(url, screenID: id)
        }
    }

    private func relaunchFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        do {
            try process.run()
        } catch {
            logger.error("Could not relaunch Finder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Hides desktop icons/widgets and optionally swaps wallpaper during capture (docs/03 §7).
///
/// User hide is a setting, so a crash still finds it on the next launch and re-asserts.
/// Capture/recording hides are session-only: a crash restores the previous Finder state
/// because those sessions did not survive.
@MainActor
final class DesktopHygieneController {
    private enum HideReason: String {
        case user
        case capture
        case recording
    }

    private struct WallpaperOverride: Codable {
        var previous: [String: String]
    }

    private let settings: AppSettings
    private let appearance: any DesktopAppearanceApplying
    private let store: UserDefaults
    private let logger = KadrLog.logger(.app)

    private var reasons: Set<HideReason> = []
    private var wallpaperOverride: WallpaperOverride?

    private static let previousIconsKey = "desktop.previousIconsVisible"
    private static let previousWidgetsKey = "desktop.previousWidgetsHidden"
    private static let wallpaperKey = "desktop.wallpaperOverride"

    init(
        settings: AppSettings,
        appearance: any DesktopAppearanceApplying = FinderDesktopAppearance(),
        store: UserDefaults = .standard
    ) {
        self.settings = settings
        self.appearance = appearance
        self.store = store
    }

    var isHidingIcons: Bool {
        settings.desktopIconsHidden || reasons.contains(.capture) || reasons.contains(.recording)
    }

    /// Re-applies a user hide, and undoes a capture wallpaper that outlived a crash.
    func reassertOnLaunch() {
        appearance.restoreLegacyIconHide()
        restoreLeftoverWallpaper()
        if settings.desktopIconsHidden {
            reasons.insert(.user)
            applyHideIfNeeded()
        } else if store.object(forKey: Self.previousIconsKey) != nil {
            // A recording or capture hide was in flight when we last died.
            applyShow()
        }
    }

    func toggleUserHide() {
        setUserHide(!settings.desktopIconsHidden)
    }

    /// Sets the hide rather than flipping it, so `kadr toggle-desktop-icons --state on`
    /// is idempotent (docs/03 §8.4).
    func setUserHide(_ hidden: Bool) {
        settings.desktopIconsHidden = hidden
        if settings.desktopIconsHidden {
            reasons.insert(.user)
            applyHideIfNeeded()
        } else {
            reasons.remove(.user)
            applyShowIfIdle()
        }
    }

    func beginCapture() {
        // Wallpaper first: the icon cover shows whatever the wallpaper is when it goes up,
        // so it must already be the capture fill.
        applyCaptureWallpaper()
        if settings.hideDesktopDuringCapture {
            reasons.insert(.capture)
            applyHideIfNeeded()
        }
    }

    /// Applies the capture appearance and waits for the screen to actually show it.
    ///
    /// The icon cover is up in the same turn; only a wallpaper swap is asynchronous, so
    /// only that waits. An ordinary capture pays nothing (docs/07 H3, docs/18 SH-4).
    func beginCaptureAndSettle() async {
        let changesAppearance = settings.captureWallpaper != .none
        beginCapture()
        guard changesAppearance else { return }
        try? await Task.sleep(for: .milliseconds(Self.settleMilliseconds))
    }

    /// Long enough for the wallpaper to repaint, short enough not to feel like lag.
    private static let settleMilliseconds = 250

    func endCapture() {
        restoreCaptureWallpaper()
        reasons.remove(.capture)
        applyShowIfIdle()
    }

    func beginRecording() {
        guard settings.hideDesktopDuringRecording else { return }
        reasons.insert(.recording)
        applyHideIfNeeded()
    }

    func endRecording() {
        reasons.remove(.recording)
        applyShowIfIdle()
    }

    /// Recording and capture sessions do not outlive quit; user hide does.
    func prepareForTermination() {
        restoreCaptureWallpaper()
        reasons.remove(.capture)
        reasons.remove(.recording)
        applyShowIfIdle()
    }

    // MARK: - Icons

    private func applyHideIfNeeded() {
        if store.object(forKey: Self.previousIconsKey) == nil {
            store.set(appearance.iconsVisible, forKey: Self.previousIconsKey)
            store.set(appearance.widgetsHidden, forKey: Self.previousWidgetsKey)
        }
        if appearance.iconsVisible {
            appearance.iconsVisible = false
        }
        if !appearance.widgetsHidden {
            appearance.widgetsHidden = true
        }
        logger.info("Desktop icons hidden")
    }

    private func applyShowIfIdle() {
        guard !isHidingIcons else { return }
        applyShow()
    }

    private func applyShow() {
        if let previous = store.object(forKey: Self.previousIconsKey) as? Bool {
            appearance.iconsVisible = previous
        } else {
            appearance.iconsVisible = true
        }
        if let previous = store.object(forKey: Self.previousWidgetsKey) as? Bool {
            appearance.widgetsHidden = previous
        } else {
            appearance.widgetsHidden = false
        }
        store.removeObject(forKey: Self.previousIconsKey)
        store.removeObject(forKey: Self.previousWidgetsKey)
        logger.info("Desktop icons restored")
    }

    // MARK: - Wallpaper

    private func applyCaptureWallpaper() {
        let fill = settings.captureWallpaper
        guard fill != .none else { return }
        guard wallpaperOverride == nil else { return }

        let previous = appearance.currentWallpaperURLs()
        let encoded = Dictionary(uniqueKeysWithValues: previous.map { (String($0.key), $0.value.path) })
        wallpaperOverride = WallpaperOverride(previous: encoded)
        persistWallpaperOverride()

        guard let url = wallpaperURL(for: fill) else { return }
        for id in previous.keys {
            appearance.applyWallpaper(url, screenID: id)
        }
    }

    private func restoreCaptureWallpaper() {
        restoreLeftoverWallpaper()
    }

    private func restoreLeftoverWallpaper() {
        let override = wallpaperOverride ?? loadWallpaperOverride()
        guard let override else { return }
        var urls: [CGDirectDisplayID: URL] = [:]
        for (key, path) in override.previous {
            guard let id = CGDirectDisplayID(key) else { continue }
            urls[id] = URL(fileURLWithPath: path)
        }
        appearance.restoreWallpapers(urls)
        wallpaperOverride = nil
        store.removeObject(forKey: Self.wallpaperKey)
    }

    private func persistWallpaperOverride() {
        guard let wallpaperOverride,
              let data = try? JSONEncoder().encode(wallpaperOverride)
        else { return }
        store.set(data, forKey: Self.wallpaperKey)
    }

    private func loadWallpaperOverride() -> WallpaperOverride? {
        guard let data = store.data(forKey: Self.wallpaperKey) else { return nil }
        return try? JSONDecoder().decode(WallpaperOverride.self, from: data)
    }

    private func wallpaperURL(for fill: CaptureWallpaper) -> URL? {
        switch fill {
        case .none:
            return nil
        case .customImage:
            let path = settings.captureWallpaperImagePath
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        case .black, .gray, .white:
            return solidWallpaperURL(fill)
        }
    }

    private func solidWallpaperURL(_ fill: CaptureWallpaper) -> URL? {
        let color: NSColor = switch fill {
        case .black: .black
        case .gray: .gray
        case .white: .white
        default: .black
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let folder = support.appendingPathComponent("Kadr/DesktopHygiene", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(fill.rawValue).png")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let size = 16
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }
}
