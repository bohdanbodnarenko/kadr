import AppKit
import CaptureCore
import MediaExport
import os
import OverlayKit
import SelectionUI
import SettingsKit
import Shared

/// Drives a scrolling capture end to end (docs/03 §1.6, docs/04 §4.4).
///
/// Two tiers, one flow. The user picks a region with the overlay they already know, then
/// either scrolls the content themselves — which needs no permission at all and is the
/// default — or lets Kadr synthesize the scrolling, which needs Accessibility and asks for
/// it at that moment. Either way the frames go to disk and the stitch happens in the
/// helper, so the agent never holds a long page.
@MainActor
@Observable
final class ScrollCaptureCoordinator {
    enum State: Equatable {
        case idle
        /// Frames are being grabbed while the page scrolls.
        case capturing
        /// The helper is joining them up.
        case stitching
    }

    @ObservationIgnored private let captureEngine: CaptureEngine
    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let overlay: SelectionOverlayController
    @ObservationIgnored private let output: CaptureOutput
    @ObservationIgnored private let vision = VisionClient()
    @ObservationIgnored private let session = ScrollCaptureSession()
    @ObservationIgnored private let scroller = AutoScroller()
    @ObservationIgnored private let logger = KadrLog.logger(.capture)

    private(set) var state: State = .idle
    private(set) var frameCount = 0
    /// The running sketch of the page so far.
    private(set) var preview: CGImage?
    /// Set while Kadr is doing the scrolling itself.
    private(set) var isAutoScrolling = false

    @ObservationIgnored private let strip = ScrollPreviewStrip()
    @ObservationIgnored private var hud: ScrollCaptureHUD?
    @ObservationIgnored private var autoScrollTask: Task<Void, Never>?
    @ObservationIgnored private var lastProfile: RowProfile?
    @ObservationIgnored private var sticky = StickyBands.none
    @ObservationIgnored private var stickyResolved = false
    @ObservationIgnored private var region: (rect: DisplayRect, display: DisplayGeometry)?

    /// Where the finished page lands: the same Quick Access path as any other capture.
    var onFinished: ((URL, PixelSize) -> Void)?

    init(
        captureEngine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        output: CaptureOutput,
        overlay: SelectionOverlayController = SelectionOverlayController()
    ) {
        self.captureEngine = captureEngine
        self.permissions = permissions
        self.settings = settings
        self.output = output
        self.overlay = overlay
    }

    var isRunning: Bool {
        state != .idle
    }

    // MARK: - Starting

    /// Picks the region to scroll through, then starts grabbing frames.
    func begin() {
        guard state == .idle else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let freezes = try await captureEngine.freezeAllDisplays()
                permissions.noteCaptureSuccess()
                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) },
                    purpose: .scrollingCapture
                ) { [weak self] outcome in
                    guard case let .region(result) = outcome else { return }
                    self?.start(region: result.rect, display: result.display)
                }
            } catch {
                permissions.noteCaptureFailure(error)
                logger
                    .error("Could not freeze for a scrolling capture: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func start(region rect: DisplayRect, display: DisplayGeometry) {
        region = (rect, display)
        lastProfile = nil
        sticky = .none
        stickyResolved = false
        frameCount = 0
        preview = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.start(
                    region: rect,
                    on: display.displayID,
                    frameRate: settings.scrollFrameRate
                ) { note in
                    Task { @MainActor [weak self] in
                        self?.received(note)
                    }
                }
                await strip.begin(frameSize: session.pixelSize)
                state = .capturing
                showHUD(over: rect, on: display)
                if settings.scrollAutoScroll {
                    startAutoScroll(in: rect, on: display)
                }
                logger.info("Scrolling capture started")
            } catch {
                permissions.noteCaptureFailure(error)
                logger.error("Scrolling capture failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Frames

    /// One frame landed: extend the preview and, if Kadr is scrolling, decide whether the
    /// page has run out.
    private func received(_ note: ScrollCaptureSession.ScrollFrameNote) {
        frameCount = note.index + 1

        defer { lastProfile = note.profile }
        guard let previous = lastProfile else {
            // The first frame is the whole of what is on screen.
            strip.append(frameAt: note.url, band: 0 ..< note.profile.height, frameHeight: note.profile.height)
            preview = strip.image
            return
        }

        var alignment = ScrollAligner.align(previous: previous, current: note.profile, sticky: sticky)
        if !stickyResolved, alignment.offset > 0 {
            stickyResolved = true
            sticky = ScrollAligner.stickyBands(
                previous: previous,
                current: note.profile,
                offset: alignment.offset
            )
            if sticky != .none {
                alignment = ScrollAligner.align(previous: previous, current: note.profile, sticky: sticky)
            }
        }

        guard alignment.offset > 0 else { return }
        let bottom = note.profile.height - sticky.footer
        strip.append(
            frameAt: note.url,
            band: max(0, bottom - alignment.offset) ..< bottom,
            frameHeight: note.profile.height
        )
        preview = strip.image
    }

    // MARK: - The auto tier

    /// Scrolls the target itself, stopping when the page stops changing (docs/04 §4.4).
    private func startAutoScroll(in rect: DisplayRect, on display: DisplayGeometry) {
        guard AutoScroller.isTrusted else {
            // Asking now rather than at launch is the whole policy (docs/04 §3.2). The
            // grant only takes effect next time, so this run stays assisted.
            AutoScroller.requestTrust()
            explainAccessibility()
            return
        }

        isAutoScrolling = true
        let centre = centrePoint(of: rect, on: display)
        let configuration = AutoScroller.Configuration(pointsPerStep: settings.scrollStepPoints)

        autoScrollTask = Task { [weak self] in
            guard let self else { return }
            var detector = ScrollSettleDetector()
            for _ in 0 ..< configuration.maximumSteps {
                if Task.isCancelled {
                    return
                }
                scroller.step(at: centre, configuration: configuration)
                try? await Task.sleep(for: .milliseconds(configuration.settleMilliseconds))
                if Task.isCancelled {
                    return
                }
                guard let profile = lastProfile else { continue }
                if detector.settled(with: profile) {
                    logger.info("Auto-scroll settled; the page has run out")
                    break
                }
            }
            isAutoScrolling = false
            stop()
        }
    }

    /// The middle of the captured region, in screen points, which is where a synthesized
    /// scroll has to land to reach the right window.
    private func centrePoint(of rect: DisplayRect, on display: DisplayGeometry) -> CGPoint {
        let screenRect = rect.inScreenSpace(GlobalCoordinateSpace.current)
        // CGEvent locations are in display space, top-left origin, which is what the rect
        // already is — the round trip is here only to make the space explicit.
        _ = screenRect
        return CGPoint(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
    }

    private func explainAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Kadr needs Accessibility to scroll for you"
        alert.informativeText = "Auto-scroll works by sending scroll events to the window "
            + "you picked, which macOS only allows with Accessibility permission. Grant it "
            + "in System Settings and try again — this capture will carry on with you doing "
            + "the scrolling."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Stopping

    /// Stops grabbing frames and asks the helper to join them up.
    func stop() {
        guard state == .capturing else { return }
        autoScrollTask?.cancel()
        autoScrollTask = nil
        isAutoScrolling = false
        state = .stitching
        hud?.showStitching()

        Task { [weak self] in
            guard let self else { return }
            let frames = await session.stop()
            guard frames.count >= 2 else {
                logger.info("Scrolling capture ended with too few frames to stitch")
                await session.discard()
                finish(nil)
                return
            }
            await stitch(frames: frames, excluding: [])
        }
    }

    /// Throws the capture away without stitching anything.
    func cancel() {
        guard state != .idle else { return }
        autoScrollTask?.cancel()
        autoScrollTask = nil
        isAutoScrolling = false
        Task { [weak self] in
            await self?.session.discard()
            self?.finish(nil)
        }
    }

    private func stitch(frames: [URL], excluding excluded: [Int]) async {
        let size = await session.pixelSize
        guard let destination = output.stagingURL(pixelSize: size) else {
            await session.discard()
            finish(nil)
            return
        }
        do {
            let response = try await vision.stitchScroll(ScrollStitchRequest(
                framePaths: frames.map(\.path),
                destinationPath: destination.path,
                excludedFrames: excluded
            ))
            vision.disconnect()

            let url = URL(fileURLWithPath: response.path)
            logger.info("Stitched \(response.pixelSize.height, privacy: .public) px of page")

            if settings.scrollReviewsSeams, !response.uncertainSeams.isEmpty {
                switch reviewSeams(response, frames: frames) {
                case .keep:
                    break
                case .retry:
                    // A retry drops the frames either side of the worst seam and joins
                    // what is left; a bad frame is usually one that landed mid-animation.
                    try? FileManager.default.removeItem(at: url)
                    let worst = response.uncertainSeams.min { $0.confidence < $1.confidence }
                    await stitch(frames: frames, excluding: worst.map { [$0.frameIndex] } ?? [])
                    return
                case .exportFrames:
                    try? FileManager.default.removeItem(at: url)
                    exportFrames(frames)
                    await session.discard()
                    finish(nil)
                    return
                }
            }

            await session.discard()
            finish(url, size: response.pixelSize)
        } catch {
            vision.disconnect()
            logger.error("Stitching failed: \(error.localizedDescription, privacy: .public)")
            presentStitchFailure(frames: frames)
            await session.discard()
            finish(nil)
        }
    }

    private func finish(_ url: URL?, size: PixelSize = PixelSize(width: 0, height: 0)) {
        hud?.dismiss()
        hud = nil
        strip.reset()
        preview = nil
        frameCount = 0
        region = nil
        state = .idle
        if let url {
            onFinished?(url, size)
        }
    }

    // MARK: - Seams the stitcher was not sure about (docs/03 §1.6)

    private enum SeamChoice {
        case keep
        case retry
        case exportFrames
    }

    private func reviewSeams(_ response: ScrollStitchResponse, frames: [URL]) -> SeamChoice {
        let count = response.uncertainSeams.count
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "One join in this capture is uncertain"
            : "\(count) joins in this capture are uncertain"
        alert.informativeText = "Kadr could not be sure how two frames line up, which "
            + "usually means the page moved in a way the overlap could not explain — a "
            + "sticky banner, an animation, or scrolling faster than the frames could "
            + "follow. Keep it if it looks right, retry without the frame that caused it, "
            + "or take the frames away and assemble them yourself."
        alert.addButton(withTitle: "Keep Anyway")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Export Frames")
        NSApp.activate()

        return switch alert.runModal() {
        case .alertSecondButtonReturn: .retry
        case .alertThirdButtonReturn: .exportFrames
        default: .keep
        }
    }

    private func presentStitchFailure(frames: [URL]) {
        let alert = NSAlert()
        alert.messageText = "Kadr could not stitch this capture"
        alert.informativeText = "The frames are still here. You can save them and put the "
            + "page together yourself."
        alert.addButton(withTitle: "Export Frames")
        alert.addButton(withTitle: "Discard")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            exportFrames(frames)
        }
    }

    /// Hands the raw frames over, which is the honest fallback when stitching cannot be
    /// trusted (docs/03 §1.6 failure mode).
    private func exportFrames(_ frames: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the \(frames.count) captured frames."
        NSApp.activate()
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let folder = directory.appendingPathComponent(
            "Kadr Scrolling Capture \(Self.folderFormatter.string(from: Date()))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for frame in frames {
                try FileManager.default.copyItem(
                    at: frame,
                    to: folder.appendingPathComponent(frame.lastPathComponent)
                )
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            logger.error("Could not export frames: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    // MARK: - The HUD

    private func showHUD(over rect: DisplayRect, on display: DisplayGeometry) {
        let hud = ScrollCaptureHUD(
            coordinator: self,
            near: rect.inScreenSpace(GlobalCoordinateSpace.current)
        )
        hud.present()
        self.hud = hud
    }
}
