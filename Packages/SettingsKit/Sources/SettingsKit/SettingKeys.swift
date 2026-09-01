import Foundation
import Shared

/// The typed key set. Names are namespaced so `defaults read app.kadr.Kadr` stays legible.
public enum SettingKeys {
    public static let schemaVersion = SettingKey("settings.schemaVersion", default: 0)
    /// Whether the user has been through onboarding (docs/03 §8.2).
    public static let hasCompletedOnboarding = SettingKey("app.hasCompletedOnboarding", default: false)
    /// Whether the one-time tip above the first capture card has been seen (docs/03 §2).
    ///
    /// Separate from onboarding, and deliberately: onboarding happens before the user has
    /// captured anything, which is the wrong moment to explain a card they have never seen.
    /// This one fires the first time there is something on screen to point at.
    public static let hasSeenQuickAccessTip = SettingKey("overlay.hasSeenQuickAccessTip", default: false)
    /// Retired by schema 3 in favour of `afterCapture`, and kept only so the migration
    /// has something to read (docs/09 U2.2).
    public static let defaultAction = SettingKey("general.defaultAction", default: DefaultCaptureAction.copyToClipboard)
    /// What happens after each kind of capture (docs/09 U2.2).
    public static let afterCapture = SettingKey("general.afterCapture", default: AfterCaptureMatrix.standard)
    /// Which actions a card offers, and where (docs/09 U2.3).
    public static let cardLayout = SettingKey("overlay.cardLayout", default: CardLayout.standard)
    /// What the Compress action aims for (docs/09 U2.4). A quarter of a megabyte pastes
    /// into anything and still reads as a screenshot.
    public static let compressionTargetBytes = SettingKey("overlay.compressionTargetBytes", default: 256 * 1024)
    /// HEIC or JPEG. HEIC is about half the size at the same quality and every Mac since
    /// 2017 reads it, but a file going to a stranger's Windows machine had better be JPEG.
    public static let compressionFormat = SettingKey("overlay.compressionFormat", default: CompressedImageFormat.heic)
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
    /// The floating Stop/Pause bar (docs/03 §1.8). On by default: the recorder shipped with
    /// no on-screen way to stop, and "I could not work out how to stop it" is the first
    /// thing anybody said about it.
    public static let recordingShowsControlBar = SettingKey("recording.showsControlBar", default: true)
    /// Seconds counted down before a recording starts (docs/03 §1.8).
    ///
    /// Its own key rather than sharing the still timer: three seconds before a screenshot is
    /// a pose, three seconds before a recording is time to put the pointer where the first
    /// shot begins — and somebody who wants one rarely wants the other.
    public static let recordingCountdownSeconds = SettingKey("recording.countdownSeconds", default: 3)
    /// Show pressed keys. Off by default and shortcuts-only by default: showing every
    /// keystroke means showing whatever gets typed into a password field.
    public static let recordingShowsKeystrokes = SettingKey("recording.showsKeystrokes", default: false)
    public static let recordingKeystrokesShortcutsOnly = SettingKey(
        "recording.keystrokesShortcutsOnly",
        default: true
    )
    public static let recordingShowsWebcam = SettingKey("recording.showsWebcam", default: false)
    /// Which camera to record. Empty means the system default, once the webcam is on.
    public static let recordingCameraDeviceID = SettingKey("recording.cameraDeviceID", default: "")
    /// Which microphone to record. Empty means the system default, once the mic is on.
    public static let recordingMicrophoneDeviceID = SettingKey("recording.microphoneDeviceID", default: "")
    /// Keep the pointer track, clicks and chords alongside a recording so it can be
    /// edited in the studio afterwards (docs/09 U3.1).
    ///
    /// On by default: the sidecar is a few kilobytes, it is the only thing that makes
    /// smooth zooms and reconstructed clicks possible later, and a recording made without
    /// it can never be given them — the information is gone the moment the recording ends.
    public static let recordingCapturesStudioSession = SettingKey(
        "recording.capturesStudioSession",
        default: true
    )
    /// Record without the system cursor and draw it back in the studio (docs/09 U3.1).
    ///
    /// Off by default, because it trades something certain for something conditional: the
    /// file that lands in the save folder has no pointer in it at all, and only a studio
    /// export brings one back. Worth turning on for a recording that will be edited, and
    /// wrong for one that will be dragged straight into a message.
    public static let recordingReconstructsCursor = SettingKey(
        "recording.reconstructsCursor",
        default: false
    )

    // MARK: - Teleprompter (docs/08)

    /// Show the script while recording.
    public static let teleprompterEnabled = SettingKey("teleprompter.enabled", default: false)
    /// The script itself. Kept in settings rather than a file because it is one text field
    /// somebody edits in Settings and reads back an hour later, not a document.
    public static let teleprompterScript = SettingKey("teleprompter.script", default: "")
    /// How fast the script scrolls when nothing is following the reader.
    public static let teleprompterWordsPerMinute = SettingKey("teleprompter.wordsPerMinute", default: 120.0)
    public static let teleprompterFontSize = SettingKey("teleprompter.fontSize", default: 30.0)
    /// Reverse the text, for reading off a beam-splitter glass.
    public static let teleprompterMirrored = SettingKey("teleprompter.mirrored", default: false)
    /// Follow the reader's voice rather than scrolling at a fixed rate.
    ///
    /// Off by default: it listens to the microphone for the length of a recording, which is
    /// not something to switch on for somebody.
    public static let teleprompterFollowsSpeech = SettingKey("teleprompter.followsSpeech", default: false)
    /// Where the panel was left, so it comes back where the reader put it.
    public static let teleprompterFrame = SettingKey("teleprompter.frame", default: "")
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

    /// Overlay pane (docs/03 §2, §8.3).
    public static let overlayCorner = SettingKey("overlay.corner", default: OverlayCorner.bottomLeft)
    // 200, down from 220. A card is a notification about something that already happened;
    // at the old size it took a fifth of the height of a laptop screen for a thumbnail
    // nobody inspects at that scale. Still adjustable in Settings for anyone who wants it
    // bigger.
    public static let overlayCardWidth = SettingKey("overlay.cardWidth", default: 200)
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
