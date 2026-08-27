#if DEBUG
    import AppKit
    import CaptureCore
    import ImageIO
    import os
    import Shared
    import UniformTypeIdentifiers

    /// Debug-build menu that exercises every `CaptureEngine` entry point and writes the
    /// result to the Desktop (docs/06 M1 step 5).
    ///
    /// There is no capture UI until M2, so this is how the ScreenCaptureKit layer gets
    /// checked against real hardware: take a shot from here, open it next to one from
    /// ⇧⌘4, and confirm they are pixel-identical.
    @MainActor
    final class DebugCaptureMenu {
        private let engine: CaptureEngine
        private let permissions: PermissionCoordinator
        private let logger = KadrLog.logger(.capture)
        private var pickerSession: ContentSharingPickerSession?

        init(engine: CaptureEngine, permissions: PermissionCoordinator) {
            self.engine = engine
            self.permissions = permissions
        }

        func makeMenuItem() -> NSMenuItem {
            let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false

            add(to: submenu, title: "Freeze All Displays", action: #selector(freezeAllDisplays))
            add(to: submenu, title: "Capture Main Display", action: #selector(captureMainDisplay))
            add(to: submenu, title: "Capture 400×300 Region", action: #selector(captureRegion))
            add(to: submenu, title: "Capture Frontmost Window", action: #selector(captureFrontmostWindow))
            submenu.addItem(.separator())
            add(to: submenu, title: "Capture via System Picker (no TCC)", action: #selector(captureViaPicker))
            submenu.addItem(.separator())
            add(to: submenu, title: "Log Permission State", action: #selector(logPermissionState))
            add(to: submenu, title: "Log Shareable Content", action: #selector(logShareableContent))

            item.submenu = submenu
            return item
        }

        private func add(to menu: NSMenu, title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // MARK: - Actions

        @objc
        private func freezeAllDisplays() {
            run("freeze") {
                let freezes = try await self.engine.freezeAllDisplays()
                for freeze in freezes {
                    try self.write(freeze.image, named: "freeze-display-\(freeze.geometry.displayID)")
                    self.logger.info(
                        """
                        Display \(freeze.geometry.displayID, privacy: .public): \
                        \(freeze.image.width, privacy: .public)×\(freeze.image.height, privacy: .public) px \
                        at \(freeze.geometry.scale.factor, privacy: .public)×
                        """
                    )
                }
            }
        }

        @objc
        private func captureMainDisplay() {
            run("captureDisplay") {
                let capture = try await self.engine.captureDisplay(CGMainDisplayID())
                try self.write(capture.image, named: "display")
            }
        }

        @objc
        private func captureRegion() {
            run("captureRegion") {
                let snapshot = try await self.engine.shareableContent()
                guard let display = snapshot.display(CGMainDisplayID()) ?? snapshot.displays.first else { return }
                // A fixed rect 100 points in from the display's top-left corner.
                let region = DisplayRect(
                    x: display.frame.minX + 100,
                    y: display.frame.minY + 100,
                    width: 400,
                    height: 300
                )
                let capture = try await self.engine.captureRegion(region, on: display.displayID)
                try self.write(capture.image, named: "region")
                self.logger.info(
                    """
                    Region \(capture.image.width, privacy: .public)×\(capture.image.height, privacy: .public) px \
                    (expected \(display.pixels(for: display.localRect(for: region)).width, privacy: .public)×\
                    \(display.pixels(for: display.localRect(for: region)).height, privacy: .public))
                    """
                )
            }
        }

        @objc
        private func captureFrontmostWindow() {
            run("captureWindow") {
                let snapshot = try await self.engine.shareableContent()
                let ownBundleID = Bundle.main.bundleIdentifier
                guard let window = snapshot.windows.first(where: {
                    $0.isUserWindow && $0.isOnScreen && $0.bundleIdentifier != ownBundleID
                }) else {
                    self.logger.error("No capturable window found")
                    return
                }
                let capture = try await self.engine.captureWindow(window.id)
                try self.write(capture.image, named: "window-\(window.applicationName ?? "unknown")")
            }
        }

        @objc
        private func captureViaPicker() {
            let session = ContentSharingPickerSession()
            pickerSession = session
            run("picker") {
                defer { self.pickerSession = nil }
                let capture = try await session.captureUserSelection()
                try self.write(capture.image, named: "picker")
            }
        }

        @objc
        private func logPermissionState() {
            let state = permissions.refresh().rawValue
            logger.info("Screen recording permission: \(state, privacy: .public)")
        }

        @objc
        private func logShareableContent() {
            run("shareableContent") {
                let snapshot = try await self.engine.shareableContent()
                let displays = snapshot.displays.count
                let windows = snapshot.windows.filter(\.isUserWindow).count
                self.logger.info(
                    "\(displays, privacy: .public) displays, \(windows, privacy: .public) user windows"
                )
            }
        }

        // MARK: - Plumbing

        private func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
            Task { @MainActor in
                do {
                    try await work()
                } catch is CancellationError {
                    logger.info("\(label, privacy: .public) cancelled")
                } catch {
                    permissions.noteCaptureFailure(error)
                    logger.error("\(label, privacy: .public) failed: \(error.localizedDescription)")
                }
            }
        }

        /// Writes a PNG to the Desktop. Debug-only; MediaExport owns real export (M4).
        private func write(_ image: CGImage, named name: String) throws {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let url = desktop.appendingPathComponent("kadr-\(name)-\(Int(Date().timeIntervalSince1970)).png")
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CocoaError(.fileWriteUnknown)
            }
            logger.info("Wrote \(url.lastPathComponent, privacy: .public)")
        }
    }
#endif
