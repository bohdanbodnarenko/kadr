import Foundation
import Shared

/// Observable façade over `UserDefaults` (docs/04 §9: plain `@Observable`, no TCA).
///
/// Properties write through on mutation, so a crash never loses a preference and
/// `defaults` on the command line always reflects the UI.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let store: UserDefaults

    public var hasCompletedOnboarding: Bool {
        didSet { store[SettingKeys.hasCompletedOnboarding] = hasCompletedOnboarding }
    }

    /// Retired in favour of `afterCapture`, and kept so the code paths that still take an
    /// old-style action keep working while they are converted (docs/09 U2.2).
    public var defaultAction: DefaultCaptureAction {
        didSet {
            store[SettingKeys.defaultAction] = defaultAction
            // Writing the old setting rewrites the matrix, so a test or a script that
            // still sets it gets the behaviour it expects rather than a silent no-op.
            afterCapture = AfterCaptureMatrix.migrating(defaultAction)
        }
    }

    /// What happens after each kind of capture (docs/09 U2.2).
    public var afterCapture: AfterCaptureMatrix {
        didSet { store[SettingKeys.afterCapture] = afterCapture }
    }

    /// The actions for a kind of capture.
    public func afterCaptureActions(for kind: CaptureKind) -> AfterCaptureActions {
        afterCapture[kind]
    }

    /// What the Compress action aims for, in bytes (docs/09 U2.4).
    public var compressionTargetBytes: Int {
        didSet { store[SettingKeys.compressionTargetBytes] = compressionTargetBytes }
    }

    public var compressionFormat: CompressedImageFormat {
        didSet { store[SettingKeys.compressionFormat] = compressionFormat }
    }

    /// Which actions a card offers, and where (docs/09 U2.3).
    public var cardLayout: CardLayout {
        didSet { store[SettingKeys.cardLayout] = cardLayout }
    }

    /// Empty means "not chosen yet"; reads resolve to the Desktop, like macOS screenshots.
    public var saveFolderPath: String {
        didSet { store[SettingKeys.saveFolderPath] = saveFolderPath }
    }

    public var filenameTemplate: String {
        didSet { store[SettingKeys.filenameTemplate] = filenameTemplate }
    }

    public var imageFormat: ImageFormat {
        didSet { store[SettingKeys.imageFormat] = imageFormat }
    }

    public var downscaleRetinaCaptures: Bool {
        didSet { store[SettingKeys.downscaleRetinaCaptures] = downscaleRetinaCaptures }
    }

    /// Convert captures to sRGB on save and copy (CleanShot §8.5). Off keeps P3.
    public var convertExportsToSRGB = SettingKeys.convertExportsToSRGB.defaultValue {
        didSet { store[SettingKeys.convertExportsToSRGB] = convertExportsToSRGB }
    }

    /// Mix each recording audio track to mono (CleanShot §13.3).
    public var recordsMono = SettingKeys.recordsMono.defaultValue {
        didSet { store[SettingKeys.recordsMono] = recordsMono }
    }

    /// Overlay Save asks for a folder and name (CleanShot §6.2).
    public var askForSaveDestination = SettingKeys.askForSaveDestination.defaultValue {
        didSet { store[SettingKeys.askForSaveDestination] = askForSaveDestination }
    }

    /// Drop the notch strip from fullscreen screenshots on notched Macs (CleanShot 4.6).
    public var cropNotchFromFullscreen = SettingKeys.cropNotchFromFullscreen.defaultValue {
        didSet { store[SettingKeys.cropNotchFromFullscreen] = cropNotchFromFullscreen }
    }

    /// Start Annotate with objects locked so drawing does not move them (CleanShot §8.1).
    public var lockCanvasByDefault = SettingKeys.lockCanvasByDefault.defaultValue {
        didSet { store[SettingKeys.lockCanvasByDefault] = lockCanvasByDefault }
    }

    /// Draw drop shadows behind inserted images in Annotate (CleanShot §8.2 / §21).
    public var objectShadowsEnabled = SettingKeys.objectShadowsEnabled.defaultValue {
        didSet { store[SettingKeys.objectShadowsEnabled] = objectShadowsEnabled }
    }

    /// Save annotated exports beside the original capture (CleanShot §7).
    public var keepOriginalWhenAnnotating = SettingKeys.keepOriginalWhenAnnotating.defaultValue {
        didSet { store[SettingKeys.keepOriginalWhenAnnotating] = keepOriginalWhenAnnotating }
    }

    /// Draw the pointer into captures.
    public var includesCursor: Bool {
        didSet { store[SettingKeys.includesCursor] = includesCursor }
    }

    /// Keep a window's drop shadow when capturing it (docs/03 §1.2).
    public var windowShadow: Bool {
        didSet { store[SettingKeys.windowShadow] = windowShadow }
    }

    /// Preserve a window's own alpha instead of compositing it onto an opaque
    /// background, so rounded corners export as real transparency (docs/03 §1.2).
    public var transparentWindowBackground: Bool {
        didSet { store[SettingKeys.transparentWindowBackground] = transparentWindowBackground }
    }

    /// Fill behind a window when transparency is off (docs/03 §1.2, CleanShot §10).
    public var windowBackdrop: WindowBackdrop = SettingKeys.windowBackdrop.defaultValue {
        didSet { store[SettingKeys.windowBackdrop] = windowBackdrop }
    }

    public var windowBackdropImagePath: String = SettingKeys.windowBackdropImagePath.defaultValue {
        didSet { store[SettingKeys.windowBackdropImagePath] = windowBackdropImagePath }
    }

    public var windowBackdropPadding: Int = SettingKeys.windowBackdropPadding.defaultValue {
        didSet { store[SettingKeys.windowBackdropPadding] = windowBackdropPadding }
    }

    /// Built-in look applied to new stills (CleanShot §9). Shift at hotkey time skips it.
    public var autoBeautifyPreset: AutoBeautifyPreset = SettingKeys.autoBeautifyPreset.defaultValue {
        didSet { store[SettingKeys.autoBeautifyPreset] = autoBeautifyPreset }
    }

    public var ocrPreservesLineBreaks: Bool = SettingKeys.ocrPreservesLineBreaks.defaultValue {
        didSet { store[SettingKeys.ocrPreservesLineBreaks] = ocrPreservesLineBreaks }
    }

    public var recordingFrameRate: RecordingQuality {
        didSet { store[SettingKeys.recordingFrameRate] = recordingFrameRate }
    }

    public var recordingCodec: RecordingVideoCodec {
        didSet { store[SettingKeys.recordingCodec] = recordingCodec }
    }

    public var recordsSystemAudio: Bool {
        didSet { store[SettingKeys.recordsSystemAudio] = recordsSystemAudio }
    }

    public var recordsMicrophone: Bool {
        didSet { store[SettingKeys.recordsMicrophone] = recordsMicrophone }
    }

    public var recordingShowsCursor: Bool {
        didSet { store[SettingKeys.recordingShowsCursor] = recordingShowsCursor }
    }

    public var recordingEnablesFocus: Bool {
        didSet { store[SettingKeys.recordingEnablesFocus] = recordingEnablesFocus }
    }

    /// Whether the floating Stop/Pause bar appears while recording (docs/03 §1.8).
    /// Whether the first-capture tip has been shown (docs/03 §2).
    public var hasSeenQuickAccessTip: Bool {
        didSet { store[SettingKeys.hasSeenQuickAccessTip] = hasSeenQuickAccessTip }
    }

    public var recordingShowsControlBar: Bool {
        didSet { store[SettingKeys.recordingShowsControlBar] = recordingShowsControlBar }
    }

    /// Seconds counted down before a recording starts (docs/03 §1.8).
    public var recordingCountdownSeconds: Int {
        didSet { store[SettingKeys.recordingCountdownSeconds] = recordingCountdownSeconds }
    }

    public var recordingShowsClicks: Bool {
        didSet { store[SettingKeys.recordingShowsClicks] = recordingShowsClicks }
    }

    public var recordingShowsKeystrokes: Bool {
        didSet { store[SettingKeys.recordingShowsKeystrokes] = recordingShowsKeystrokes }
    }

    public var recordingKeystrokesShortcutsOnly: Bool {
        didSet { store[SettingKeys.recordingKeystrokesShortcutsOnly] = recordingKeystrokesShortcutsOnly }
    }

    public var recordingShowsWebcam: Bool {
        didSet { store[SettingKeys.recordingShowsWebcam] = recordingShowsWebcam }
    }

    public var recordingWebcamCircular: Bool {
        get {
            access(keyPath: \.recordingWebcamCircular)
            return store[SettingKeys.recordingWebcamCircular]
        }
        set {
            withMutation(keyPath: \.recordingWebcamCircular) {
                store[SettingKeys.recordingWebcamCircular] = newValue
            }
        }
    }

    public var recordingWebcamFillsFrame: Bool {
        get {
            access(keyPath: \.recordingWebcamFillsFrame)
            return store[SettingKeys.recordingWebcamFillsFrame]
        }
        set {
            withMutation(keyPath: \.recordingWebcamFillsFrame) {
                store[SettingKeys.recordingWebcamFillsFrame] = newValue
            }
        }
    }

    public var recordingWebcamSize: Double {
        get {
            access(keyPath: \.recordingWebcamSize)
            return store[SettingKeys.recordingWebcamSize]
        }
        set {
            withMutation(keyPath: \.recordingWebcamSize) {
                store[SettingKeys.recordingWebcamSize] = min(max(newValue, 0.08), 0.6)
            }
        }
    }

    public var recordingKeystrokePosition: RecordingKeystrokePosition {
        get {
            access(keyPath: \.recordingKeystrokePosition)
            return store[SettingKeys.recordingKeystrokePosition]
        }
        set {
            withMutation(keyPath: \.recordingKeystrokePosition) {
                store[SettingKeys.recordingKeystrokePosition] = newValue
            }
        }
    }

    public var recordingKeystrokeAppearance: OverlayChromeAppearance {
        get {
            access(keyPath: \.recordingKeystrokeAppearance)
            return store[SettingKeys.recordingKeystrokeAppearance]
        }
        set {
            withMutation(keyPath: \.recordingKeystrokeAppearance) {
                store[SettingKeys.recordingKeystrokeAppearance] = newValue
            }
        }
    }

    public var recordingKeystrokeScale: Double {
        get {
            access(keyPath: \.recordingKeystrokeScale)
            return store[SettingKeys.recordingKeystrokeScale]
        }
        set {
            withMutation(keyPath: \.recordingKeystrokeScale) {
                store[SettingKeys.recordingKeystrokeScale] = min(max(newValue, 0.6), 1.8)
            }
        }
    }

    public var recordingClickFilled: Bool {
        get {
            access(keyPath: \.recordingClickFilled)
            return store[SettingKeys.recordingClickFilled]
        }
        set {
            withMutation(keyPath: \.recordingClickFilled) {
                store[SettingKeys.recordingClickFilled] = newValue
            }
        }
    }

    public var recordingClickScale: Double {
        get {
            access(keyPath: \.recordingClickScale)
            return store[SettingKeys.recordingClickScale]
        }
        set {
            withMutation(keyPath: \.recordingClickScale) {
                store[SettingKeys.recordingClickScale] = min(max(newValue, 0.5), 4)
            }
        }
    }

    public var recordingClickRed: Double {
        get {
            access(keyPath: \.recordingClickRed)
            return store[SettingKeys.recordingClickRed]
        }
        set {
            withMutation(keyPath: \.recordingClickRed) {
                store[SettingKeys.recordingClickRed] = min(max(newValue, 0), 1)
            }
        }
    }

    public var recordingClickGreen: Double {
        get {
            access(keyPath: \.recordingClickGreen)
            return store[SettingKeys.recordingClickGreen]
        }
        set {
            withMutation(keyPath: \.recordingClickGreen) {
                store[SettingKeys.recordingClickGreen] = min(max(newValue, 0), 1)
            }
        }
    }

    public var recordingClickBlue: Double {
        get {
            access(keyPath: \.recordingClickBlue)
            return store[SettingKeys.recordingClickBlue]
        }
        set {
            withMutation(keyPath: \.recordingClickBlue) {
                store[SettingKeys.recordingClickBlue] = min(max(newValue, 0), 1)
            }
        }
    }

    /// Which camera to record when the webcam is on. Empty is the system default.
    ///
    /// Computed so it does not grow the initializer: device ids are strings with no
    /// defaulting logic beyond the key itself.
    public var recordingCameraDeviceID: String {
        get {
            access(keyPath: \.recordingCameraDeviceID)
            return store[SettingKeys.recordingCameraDeviceID]
        }
        set {
            withMutation(keyPath: \.recordingCameraDeviceID) {
                store[SettingKeys.recordingCameraDeviceID] = newValue
            }
        }
    }

    /// Which microphone to record when the mic is on. Empty is the system default.
    public var recordingMicrophoneDeviceID: String {
        get {
            access(keyPath: \.recordingMicrophoneDeviceID)
            return store[SettingKeys.recordingMicrophoneDeviceID]
        }
        set {
            withMutation(keyPath: \.recordingMicrophoneDeviceID) {
                store[SettingKeys.recordingMicrophoneDeviceID] = newValue
            }
        }
    }

    public var recordingCapturesStudioSession: Bool {
        didSet { store[SettingKeys.recordingCapturesStudioSession] = recordingCapturesStudioSession }
    }

    public var recordingReconstructsCursor: Bool {
        didSet { store[SettingKeys.recordingReconstructsCursor] = recordingReconstructsCursor }
    }

    public var teleprompterEnabled: Bool {
        didSet { store[SettingKeys.teleprompterEnabled] = teleprompterEnabled }
    }

    public var teleprompterScript: String {
        didSet { store[SettingKeys.teleprompterScript] = teleprompterScript }
    }

    public var teleprompterWordsPerMinute: Double {
        didSet { store[SettingKeys.teleprompterWordsPerMinute] = teleprompterWordsPerMinute }
    }

    public var teleprompterFontSize: Double {
        didSet { store[SettingKeys.teleprompterFontSize] = teleprompterFontSize }
    }

    public var teleprompterMirrored: Bool {
        didSet { store[SettingKeys.teleprompterMirrored] = teleprompterMirrored }
    }

    public var teleprompterFollowsSpeech: Bool {
        didSet { store[SettingKeys.teleprompterFollowsSpeech] = teleprompterFollowsSpeech }
    }

    /// Nil rather than empty when it has never been placed, so the panel can tell "put it
    /// where I left it" from "this is the first time".
    public var teleprompterFrame: String? {
        didSet { store[SettingKeys.teleprompterFrame] = teleprompterFrame ?? "" }
    }

    public var scrollAutoScroll: Bool {
        didSet { store[SettingKeys.scrollAutoScroll] = scrollAutoScroll }
    }

    public var scrollStepPoints: Int {
        didSet { store[SettingKeys.scrollStepPoints] = scrollStepPoints }
    }

    public var scrollFrameRate: Int {
        didSet { store[SettingKeys.scrollFrameRate] = scrollFrameRate }
    }

    public var scrollAxis: ScrollAxis {
        didSet { store[SettingKeys.scrollAxis] = scrollAxis }
    }

    public var scrollReviewsSeams: Bool {
        didSet { store[SettingKeys.scrollReviewsSeams] = scrollReviewsSeams }
    }

    public var selfTimer: SelfTimer {
        didSet { store[SettingKeys.selfTimer] = selfTimer }
    }

    /// A typed timer value, used when it is longer than any preset. Zero means unused.
    public var customTimerSeconds: Int {
        didSet { store[SettingKeys.customTimerSeconds] = max(0, customTimerSeconds) }
    }

    public var overlayCorner: OverlayCorner {
        didSet { store[SettingKeys.overlayCorner] = overlayCorner }
    }

    /// Card width in points, clamped so a stray value cannot produce an unusable card.
    ///
    /// Computed rather than stored with a `didSet`: assigning to a property inside its
    /// own observer crashes the `@Observable` macro's generated accessors, so clamping
    /// goes through the manual observation API instead.
    public var overlayCardWidth: Int {
        get {
            access(keyPath: \.overlayCardWidth)
            return Self.clamp(store[SettingKeys.overlayCardWidth], to: 140 ... 420)
        }
        set {
            withMutation(keyPath: \.overlayCardWidth) {
                store[SettingKeys.overlayCardWidth] = Self.clamp(newValue, to: 140 ... 420)
            }
        }
    }

    public var overlayTimeout: OverlayTimeout {
        didSet { store[SettingKeys.overlayTimeout] = overlayTimeout }
    }

    /// Cards shown before older ones collapse behind the stack (docs/03 §2).
    public var overlayMaxVisibleCards: Int {
        get {
            access(keyPath: \.overlayMaxVisibleCards)
            return Self.clamp(store[SettingKeys.overlayMaxVisibleCards], to: 1 ... 10)
        }
        set {
            withMutation(keyPath: \.overlayMaxVisibleCards) {
                store[SettingKeys.overlayMaxVisibleCards] = Self.clamp(newValue, to: 1 ... 10)
            }
        }
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public var overlayOnPrimaryDisplay: Bool {
        didSet { store[SettingKeys.overlayOnPrimaryDisplay] = overlayOnPrimaryDisplay }
    }

    public var overlayDismissOnDrag: Bool {
        didSet { store[SettingKeys.overlayDismissOnDrag] = overlayDismissOnDrag }
    }

    /// Return saves the hovered card and dismisses it (CleanShot §6.2).
    public var overlayReturnSaves: Bool {
        didSet { store[SettingKeys.overlayReturnSaves] = overlayReturnSaves }
    }

    /// Last All-in-One mode, so Return on the HUD repeats it (docs/03 §1.4).
    ///
    /// Computed so it does not grow the initializer: it is a remembered string, not a
    /// setting the reset sheet needs to reason about beyond writing the default.
    public var lastAllInOneMode: String {
        get {
            access(keyPath: \.lastAllInOneMode)
            return store[SettingKeys.lastAllInOneMode]
        }
        set {
            withMutation(keyPath: \.lastAllInOneMode) {
                store[SettingKeys.lastAllInOneMode] = newValue
            }
        }
    }

    public var historyRetention: HistoryRetention {
        didSet { store[SettingKeys.historyRetention] = historyRetention }
    }

    public var historySizeCap: HistorySizeCap {
        didSet { store[SettingKeys.historySizeCap] = historySizeCap }
    }

    /// Whether captures are read for the History search index (docs/03 §5 P3).
    public var historyIndexesText: Bool {
        didSet { store[SettingKeys.historyIndexesText] = historyIndexesText }
    }

    public var desktopIconsHidden: Bool {
        didSet { store[SettingKeys.desktopIconsHidden] = desktopIconsHidden }
    }

    public var hideDesktopDuringCapture: Bool {
        didSet { store[SettingKeys.hideDesktopDuringCapture] = hideDesktopDuringCapture }
    }

    public var hideDesktopDuringRecording: Bool {
        didSet { store[SettingKeys.hideDesktopDuringRecording] = hideDesktopDuringRecording }
    }

    public var captureWallpaper: CaptureWallpaper {
        didSet { store[SettingKeys.captureWallpaper] = captureWallpaper }
    }

    public var captureWallpaperImagePath: String {
        didSet { store[SettingKeys.captureWallpaperImagePath] = captureWallpaperImagePath }
    }

    public var capturePrecisionCrosshair: Bool {
        didSet { store[SettingKeys.capturePrecisionCrosshair] = capturePrecisionCrosshair }
    }

    /// Whether stills keep the display's HDR range (macOS 15+, docs/06 M25).
    public var captureDynamicRange: DynamicRange {
        didSet { store[SettingKeys.captureDynamicRange] = captureDynamicRange }
    }

    /// Whether recordings keep the display's HDR range (macOS 15+, docs/06 M25).
    public var recordingDynamicRange: DynamicRange {
        didSet { store[SettingKeys.recordingDynamicRange] = recordingDynamicRange }
    }

    /// Whether a selection sticks to the edges Kadr finds in the frozen screen
    /// (docs/03 §8.3 "snapping", docs/06 M21).
    public var captureSnapsToEdges: Bool {
        didSet { store[SettingKeys.captureSnapsToEdges] = captureSnapsToEdges }
    }

    /// How long a capture waits, taking the custom value into account (docs/03 §1.5).
    public var timerSeconds: Int {
        customTimerSeconds > 0 ? customTimerSeconds : selfTimer.seconds
    }

    /// Every key is assigned from the store; splitting the list would hide a missed load.
    public init(store: UserDefaults = .standard) {
        SettingsMigrator.migrate(store)
        self.store = store
        hasCompletedOnboarding = store[SettingKeys.hasCompletedOnboarding]
        defaultAction = store[SettingKeys.defaultAction]
        afterCapture = store[SettingKeys.afterCapture]
        compressionTargetBytes = store[SettingKeys.compressionTargetBytes]
        compressionFormat = store[SettingKeys.compressionFormat]
        cardLayout = store[SettingKeys.cardLayout]
        saveFolderPath = store[SettingKeys.saveFolderPath]
        filenameTemplate = store[SettingKeys.filenameTemplate]
        imageFormat = store[SettingKeys.imageFormat]
        downscaleRetinaCaptures = store[SettingKeys.downscaleRetinaCaptures]
        includesCursor = store[SettingKeys.includesCursor]
        windowShadow = store[SettingKeys.windowShadow]
        transparentWindowBackground = store[SettingKeys.transparentWindowBackground]
        recordingFrameRate = store[SettingKeys.recordingFrameRate]
        recordingCodec = store[SettingKeys.recordingCodec]
        recordsSystemAudio = store[SettingKeys.recordsSystemAudio]
        recordsMicrophone = store[SettingKeys.recordsMicrophone]
        recordingShowsCursor = store[SettingKeys.recordingShowsCursor]
        recordingEnablesFocus = store[SettingKeys.recordingEnablesFocus]
        hasSeenQuickAccessTip = store[SettingKeys.hasSeenQuickAccessTip]
        recordingShowsControlBar = store[SettingKeys.recordingShowsControlBar]
        recordingCountdownSeconds = store[SettingKeys.recordingCountdownSeconds]
        recordingShowsClicks = store[SettingKeys.recordingShowsClicks]
        recordingShowsKeystrokes = store[SettingKeys.recordingShowsKeystrokes]
        recordingKeystrokesShortcutsOnly = store[SettingKeys.recordingKeystrokesShortcutsOnly]
        recordingShowsWebcam = store[SettingKeys.recordingShowsWebcam]
        recordingCapturesStudioSession = store[SettingKeys.recordingCapturesStudioSession]
        recordingReconstructsCursor = store[SettingKeys.recordingReconstructsCursor]
        teleprompterEnabled = store[SettingKeys.teleprompterEnabled]
        teleprompterScript = store[SettingKeys.teleprompterScript]
        teleprompterWordsPerMinute = store[SettingKeys.teleprompterWordsPerMinute]
        teleprompterFontSize = store[SettingKeys.teleprompterFontSize]
        teleprompterMirrored = store[SettingKeys.teleprompterMirrored]
        teleprompterFollowsSpeech = store[SettingKeys.teleprompterFollowsSpeech]
        teleprompterFrame = store[SettingKeys.teleprompterFrame]
        scrollAutoScroll = store[SettingKeys.scrollAutoScroll]
        scrollStepPoints = store[SettingKeys.scrollStepPoints]
        scrollFrameRate = store[SettingKeys.scrollFrameRate]
        scrollAxis = store[SettingKeys.scrollAxis]
        scrollReviewsSeams = store[SettingKeys.scrollReviewsSeams]
        selfTimer = store[SettingKeys.selfTimer]
        customTimerSeconds = store[SettingKeys.customTimerSeconds]
        overlayCorner = store[SettingKeys.overlayCorner]
        overlayTimeout = store[SettingKeys.overlayTimeout]
        overlayOnPrimaryDisplay = store[SettingKeys.overlayOnPrimaryDisplay]
        overlayDismissOnDrag = store[SettingKeys.overlayDismissOnDrag]
        overlayReturnSaves = store[SettingKeys.overlayReturnSaves]
        historyRetention = store[SettingKeys.historyRetention]
        historySizeCap = store[SettingKeys.historySizeCap]
        historyIndexesText = store[SettingKeys.historyIndexesText]
        desktopIconsHidden = store[SettingKeys.desktopIconsHidden]
        hideDesktopDuringCapture = store[SettingKeys.hideDesktopDuringCapture]
        hideDesktopDuringRecording = store[SettingKeys.hideDesktopDuringRecording]
        captureWallpaper = store[SettingKeys.captureWallpaper]
        captureWallpaperImagePath = store[SettingKeys.captureWallpaperImagePath]
        capturePrecisionCrosshair = store[SettingKeys.capturePrecisionCrosshair]
        captureSnapsToEdges = store[SettingKeys.captureSnapsToEdges]
        captureDynamicRange = store[SettingKeys.captureDynamicRange].resolved
        recordingDynamicRange = store[SettingKeys.recordingDynamicRange].resolved
        readWindowFill()
    }

    private func readWindowFill() {
        windowBackdrop = store[SettingKeys.windowBackdrop]
        windowBackdropImagePath = store[SettingKeys.windowBackdropImagePath]
        windowBackdropPadding = store[SettingKeys.windowBackdropPadding]
        convertExportsToSRGB = store[SettingKeys.convertExportsToSRGB]
        recordsMono = store[SettingKeys.recordsMono]
        askForSaveDestination = store[SettingKeys.askForSaveDestination]
        cropNotchFromFullscreen = store[SettingKeys.cropNotchFromFullscreen]
        lockCanvasByDefault = store[SettingKeys.lockCanvasByDefault]
        objectShadowsEnabled = store[SettingKeys.objectShadowsEnabled]
        keepOriginalWhenAnnotating = store[SettingKeys.keepOriginalWhenAnnotating]
        autoBeautifyPreset = store[SettingKeys.autoBeautifyPreset]
        ocrPreservesLineBreaks = store[SettingKeys.ocrPreservesLineBreaks]
    }

    /// Where captures are written. Falls back to the Desktop until the user picks a folder.
    public var saveFolder: URL {
        guard !saveFolderPath.isEmpty else { return Self.defaultSaveFolder }
        return URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    public static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
