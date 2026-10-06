import AppKit
import Foundation
import StudioSession
import UniformTypeIdentifiers

/// Importing a still that fills the studio canvas (docs/09 U3.5).
@MainActor
public extension StudioDocumentModel {
    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to fill the area around the recording."
        presentPanel(panel) { [weak self] url in
            self?.importWallpaper(from: url)
        }
    }

    /// Copies `url` into the session and uses it as the canvas fill.
    func importWallpaper(from url: URL) {
        do {
            let fileName = try session.replaceWallpaper(copying: url)
            BackdropRecents.remember(url.path)
            change {
                $0.canvas.wallpaperFileName = fileName
                $0.canvas.setBackdropKind(.wallpaper)
            }
            notice = "Using \(url.lastPathComponent) as the wallpaper."
        } catch {
            failure = .importFailed(error.localizedDescription)
        }
    }

    /// Forgets the wallpaper. The file stays until the edit is committed on close, so
    /// undoing this still finds it (docs/17 T-STU-9).
    func removeWallpaper() {
        change {
            $0.canvas.wallpaperFileName = nil
            if case .wallpaper = $0.canvas.background {
                $0.canvas.setBackdropKind(.none)
            }
        }
    }
}
