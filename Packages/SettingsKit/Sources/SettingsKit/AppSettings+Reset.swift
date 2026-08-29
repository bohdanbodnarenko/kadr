import Foundation

/// Putting every setting back the way it shipped (docs/03 §8.3).
///
/// In its own file because it is one long list that grows with every key, and leaving it in
/// the class made `AppSettings` read as mostly-reset rather than mostly-settings. Each entry
/// is deliberately spelled out against `SettingKeys` rather than looped: a reset that
/// silently misses a key is a reset that leaves somebody's problem behind.
public extension AppSettings {
    /// Restores every key to its default. Used by Settings → Advanced → Reset (docs/03 §8.3).
    func resetToDefaults() {
        defaultAction = SettingKeys.defaultAction.defaultValue
        afterCapture = SettingKeys.afterCapture.defaultValue
        compressionTargetBytes = SettingKeys.compressionTargetBytes.defaultValue
        compressionFormat = SettingKeys.compressionFormat.defaultValue
        cardLayout = SettingKeys.cardLayout.defaultValue
        saveFolderPath = SettingKeys.saveFolderPath.defaultValue
        filenameTemplate = SettingKeys.filenameTemplate.defaultValue
        imageFormat = SettingKeys.imageFormat.defaultValue
        downscaleRetinaCaptures = SettingKeys.downscaleRetinaCaptures.defaultValue
        includesCursor = SettingKeys.includesCursor.defaultValue
        windowShadow = SettingKeys.windowShadow.defaultValue
        transparentWindowBackground = SettingKeys.transparentWindowBackground.defaultValue
        ocrPreservesLineBreaks = SettingKeys.ocrPreservesLineBreaks.defaultValue
        recordingFrameRate = SettingKeys.recordingFrameRate.defaultValue
        recordingCodec = SettingKeys.recordingCodec.defaultValue
        recordsSystemAudio = SettingKeys.recordsSystemAudio.defaultValue
        recordsMicrophone = SettingKeys.recordsMicrophone.defaultValue
        recordingShowsCursor = SettingKeys.recordingShowsCursor.defaultValue
        recordingEnablesFocus = SettingKeys.recordingEnablesFocus.defaultValue
        recordingShowsClicks = SettingKeys.recordingShowsClicks.defaultValue
        recordingShowsKeystrokes = SettingKeys.recordingShowsKeystrokes.defaultValue
        recordingKeystrokesShortcutsOnly = SettingKeys.recordingKeystrokesShortcutsOnly.defaultValue
        recordingShowsWebcam = SettingKeys.recordingShowsWebcam.defaultValue
        recordingCapturesStudioSession = SettingKeys.recordingCapturesStudioSession.defaultValue
        recordingReconstructsCursor = SettingKeys.recordingReconstructsCursor.defaultValue
        scrollAutoScroll = SettingKeys.scrollAutoScroll.defaultValue
        scrollStepPoints = SettingKeys.scrollStepPoints.defaultValue
        scrollFrameRate = SettingKeys.scrollFrameRate.defaultValue
        scrollReviewsSeams = SettingKeys.scrollReviewsSeams.defaultValue
        selfTimer = SettingKeys.selfTimer.defaultValue
        customTimerSeconds = SettingKeys.customTimerSeconds.defaultValue
        overlayCorner = SettingKeys.overlayCorner.defaultValue
        overlayCardWidth = SettingKeys.overlayCardWidth.defaultValue
        overlayTimeout = SettingKeys.overlayTimeout.defaultValue
        overlayMaxVisibleCards = SettingKeys.overlayMaxVisibleCards.defaultValue
        overlayOnPrimaryDisplay = SettingKeys.overlayOnPrimaryDisplay.defaultValue
        overlayDismissOnDrag = SettingKeys.overlayDismissOnDrag.defaultValue
        historyRetention = SettingKeys.historyRetention.defaultValue
        historySizeCap = SettingKeys.historySizeCap.defaultValue
        historyIndexesText = SettingKeys.historyIndexesText.defaultValue
        desktopIconsHidden = SettingKeys.desktopIconsHidden.defaultValue
        hideDesktopDuringCapture = SettingKeys.hideDesktopDuringCapture.defaultValue
        hideDesktopDuringRecording = SettingKeys.hideDesktopDuringRecording.defaultValue
        captureWallpaper = SettingKeys.captureWallpaper.defaultValue
        captureWallpaperImagePath = SettingKeys.captureWallpaperImagePath.defaultValue
        capturePrecisionCrosshair = SettingKeys.capturePrecisionCrosshair.defaultValue
        captureSnapsToEdges = SettingKeys.captureSnapsToEdges.defaultValue
        captureDynamicRange = SettingKeys.captureDynamicRange.defaultValue
        recordingDynamicRange = SettingKeys.recordingDynamicRange.defaultValue
    }
}
