import Foundation
import Shared

/// The typed key set. Names are namespaced so `defaults read app.kadr.Kadr` stays legible.
public enum SettingKeys {
    public static let schemaVersion = SettingKey("settings.schemaVersion", default: 0)
    /// Whether the user has been through onboarding (docs/03 §8.2).
    public static let hasCompletedOnboarding = SettingKey("app.hasCompletedOnboarding", default: false)
    /// Retired by schema 3 in favour of `afterCapture`, and kept only so the migration
    /// has something to read (docs/09 U2.2).
    public static let defaultAction = SettingKey("general.defaultAction", default: DefaultCaptureAction.copyToClipboard)
    /// What happens after each kind of capture (docs/09 U2.2).
    public static let afterCapture = SettingKey("general.afterCapture", default: AfterCaptureMatrix.standard)
    public static let saveFolderPath = SettingKey("general.saveFolderPath", default: "")
    public static let filenameTemplate = SettingKey("general.filenameTemplate", default: "{app}-{date}-{time}")
    public static let imageFormat = SettingKey("general.imageFormat", default: ImageFormat.png)
    public static let downscaleRetinaCaptures = SettingKey("general.downscaleRetinaCaptures", default: false)

    // Capture pane (docs/03 §8.3).
    public static let includesCursor = SettingKey("capture.includesCursor", default: false)
    public static let windowShadow = SettingKey("capture.windowShadow", default: true)
    public static let transparentWindowBackground = SettingKey("capture.transparentWindowBackground", default: true)
    /// Custom timer values live alongside the presets so a typed value survives a
    /// round-trip through the presets picker.
    public static let selfTimer = SettingKey("capture.selfTimer", default: SelfTimer.off)
    public static let customTimerSeconds = SettingKey("capture.customTimerSeconds", default: 0)
    /// Keep the line structure of recognised text, or fold it into spaces (docs/03 §1.7).
    public static let ocrPreservesLineBreaks = SettingKey("capture.ocrPreservesLineBreaks", default: true)
    /// Pull the selection onto the edges Kadr finds in the frozen screen (docs/06 M21).
    public static let captureSnapsToEdges = SettingKey("capture.snapsToEdges", default: true)
    /// Keep the display's HDR range in stills (macOS 15+, docs/06 M25). Standard by
    /// default: an HDR screenshot looks wrong in apps that do not understand one.
    public static let captureDynamicRange = SettingKey("capture.dynamicRange", default: DynamicRange.standard)

    // Recording pane (docs/03 §1.8, §8.3).
    public static let recordingFrameRate = SettingKey("recording.frameRate", default: RecordingQuality.sixty)
    public static let recordingCodec = SettingKey("recording.codec", default: RecordingVideoCodec.hevc)
    public static let recordsSystemAudio = SettingKey("recording.systemAudio", default: true)
    public static let recordsMicrophone = SettingKey("recording.microphone", default: false)
    public static let recordingShowsCursor = SettingKey("recording.showsCursor", default: true)
    /// Turn on Do Not Disturb while recording, so notifications stay out of the file.
    public static let recordingEnablesFocus = SettingKey("recording.enablesFocus", default: true)
    /// Draw a halo where the user clicks (docs/03 §1.8).
    public static let recordingShowsClicks = SettingKey("recording.showsClicks", default: false)
    /// Show pressed keys. Off by default and shortcuts-only by default: showing every
    /// keystroke means showing whatever gets typed into a password field.
    public static let recordingShowsKeystrokes = SettingKey("recording.showsKeystrokes", default: false)
    public static let recordingKeystrokesShortcutsOnly = SettingKey(
        "recording.keystrokesShortcutsOnly",
        default: true
    )
    public static let recordingShowsWebcam = SettingKey("recording.showsWebcam", default: false)
    /// Keep the display's HDR range in recordings (macOS 15+, docs/06 M25).
    public static let recordingDynamicRange = SettingKey(
        "recording.dynamicRange",
        default: DynamicRange.standard
    )

    // MARK: Scrolling capture (docs/03 §1.6)

    /// Let Kadr do the scrolling. Off by default: it needs Accessibility, and the
    /// assisted tier needs no permission at all.
    public static let scrollAutoScroll = SettingKey("scroll.autoScroll", default: false)
    /// Points per synthesized scroll step. Smaller means more overlap and a safer stitch.
    public static let scrollStepPoints = SettingKey("scroll.stepPoints", default: 120)
    /// Frames a second while the user scrolls.
    public static let scrollFrameRate = SettingKey("scroll.frameRate", default: 8)
    /// Show the seam review when the stitch is not sure (docs/03 §1.6 failure mode).
    public static let scrollReviewsSeams = SettingKey("scroll.reviewsSeams", default: true)

    // Overlay pane (docs/03 §2, §8.3).
    public static let overlayCorner = SettingKey("overlay.corner", default: OverlayCorner.bottomLeft)
    public static let overlayCardWidth = SettingKey("overlay.cardWidth", default: 220)
    public static let overlayTimeout = SettingKey("overlay.timeout", default: OverlayTimeout.never)
    /// Cards visible before older ones collapse behind the stack (docs/03 §2).
    public static let overlayMaxVisibleCards = SettingKey("overlay.maxVisibleCards", default: 5)
    /// Always show cards on the primary display instead of the capture's display.
    public static let overlayOnPrimaryDisplay = SettingKey("overlay.onPrimaryDisplay", default: false)
    /// Remove the card when its file is dragged out (docs/03 §2).
    public static let overlayDismissOnDrag = SettingKey("overlay.dismissOnDrag", default: true)

    // History pane (docs/03 §5, §8.3).
    public static let historyRetention = SettingKey("history.retention", default: HistoryRetention.forever)
    public static let historySizeCap = SettingKey("history.sizeCap", default: HistorySizeCap.gigabytes5)
    /// Read the text in captures so History can be searched (docs/03 §5 P3).
    ///
    /// On by default and opt-*out*: the index never leaves the machine, and a library you
    /// cannot search is most of the reason people never open one. The work runs in the
    /// helper process, on mains power only, so leaving it on costs nothing at idle.
    public static let historyIndexesText = SettingKey("history.indexesText", default: true)
}
