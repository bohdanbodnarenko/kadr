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
        resetGeneral()
        resetCapture()
        resetRecording()
        resetChrome()
    }

    private func resetGeneral() {
        defaultAction = SettingKeys.defaultAction.defaultValue
        resumeOnboardingAtPermissions = SettingKeys.resumeOnboardingAtPermissions.defaultValue
        afterCapture = SettingKeys.afterCapture.defaultValue
        compressionTargetBytes = SettingKeys.compressionTargetBytes.defaultValue
        compressionFormat = SettingKeys.compressionFormat.defaultValue
        cardLayout = SettingKeys.cardLayout.defaultValue
        saveFolderPath = SettingKeys.saveFolderPath.defaultValue
        filenameTemplate = SettingKeys.filenameTemplate.defaultValue
        imageFormat = SettingKeys.imageFormat.defaultValue
        downscaleRetinaCaptures = SettingKeys.downscaleRetinaCaptures.defaultValue
        convertExportsToSRGB = SettingKeys.convertExportsToSRGB.defaultValue
        askForSaveDestination = SettingKeys.askForSaveDestination.defaultValue
        playsCaptureSound = SettingKeys.playsCaptureSound.defaultValue
        lossyQuality = SettingKeys.lossyQuality.defaultValue
        showsMenuBarIcon = SettingKeys.showsMenuBarIcon.defaultValue
    }

    private func resetCapture() {
        includesCursor = SettingKeys.includesCursor.defaultValue
        windowShadow = SettingKeys.windowShadow.defaultValue
        transparentWindowBackground = SettingKeys.transparentWindowBackground.defaultValue
        windowBackdrop = SettingKeys.windowBackdrop.defaultValue
        windowBackdropImagePath = SettingKeys.windowBackdropImagePath.defaultValue
        windowBackdropPadding = SettingKeys.windowBackdropPadding.defaultValue
        autoBeautifyPreset = SettingKeys.autoBeautifyPreset.defaultValue
        cropNotchFromFullscreen = SettingKeys.cropNotchFromFullscreen.defaultValue
        fullscreenTarget = SettingKeys.fullscreenTarget.defaultValue
        lockCanvasByDefault = SettingKeys.lockCanvasByDefault.defaultValue
        objectShadowsEnabled = SettingKeys.objectShadowsEnabled.defaultValue
        keepOriginalWhenAnnotating = SettingKeys.keepOriginalWhenAnnotating.defaultValue
        ocrPreservesLineBreaks = SettingKeys.ocrPreservesLineBreaks.defaultValue
        ocrShowsReview = SettingKeys.ocrShowsReview.defaultValue
        captureShowsOverlayHints = SettingKeys.captureShowsOverlayHints.defaultValue
        captureConfirmsSelection = SettingKeys.captureConfirmsSelection.defaultValue
        selfTimer = SettingKeys.selfTimer.defaultValue
        customTimerSeconds = SettingKeys.customTimerSeconds.defaultValue
        rememberedCustomTimerSeconds = SettingKeys.rememberedCustomTimerSeconds.defaultValue
        scrollAutoScroll = SettingKeys.scrollAutoScroll.defaultValue
        scrollStepPoints = SettingKeys.scrollStepPoints.defaultValue
        scrollFrameRate = SettingKeys.scrollFrameRate.defaultValue
        scrollAxis = SettingKeys.scrollAxis.defaultValue
        scrollReviewsSeams = SettingKeys.scrollReviewsSeams.defaultValue
        capturePrecisionCrosshair = SettingKeys.capturePrecisionCrosshair.defaultValue
        captureSnapsToEdges = SettingKeys.captureSnapsToEdges.defaultValue
        captureSelectionAspect = SettingKeys.captureSelectionAspect.defaultValue
        captureDynamicRange = SettingKeys.captureDynamicRange.defaultValue
    }

    private func resetRecording() {
        recordingFrameRate = SettingKeys.recordingFrameRate.defaultValue
        recordingCodec = SettingKeys.recordingCodec.defaultValue
        recordsSystemAudio = SettingKeys.recordsSystemAudio.defaultValue
        recordsMicrophone = SettingKeys.recordsMicrophone.defaultValue
        recordsMono = SettingKeys.recordsMono.defaultValue
        recordingShowsCursor = SettingKeys.recordingShowsCursor.defaultValue
        recordingShowsClicks = SettingKeys.recordingShowsClicks.defaultValue
        recordingShowsKeystrokes = SettingKeys.recordingShowsKeystrokes.defaultValue
        recordingKeystrokesShortcutsOnly = SettingKeys.recordingKeystrokesShortcutsOnly.defaultValue
        recordingShowsControlBar = SettingKeys.recordingShowsControlBar.defaultValue
        recordingControlChrome = SettingKeys.recordingControlChrome.defaultValue
        recordingCountdownSeconds = SettingKeys.recordingCountdownSeconds.defaultValue
        recordingShowsWebcam = SettingKeys.recordingShowsWebcam.defaultValue
        recordingWebcamCircular = SettingKeys.recordingWebcamCircular.defaultValue
        recordingWebcamFillsFrame = SettingKeys.recordingWebcamFillsFrame.defaultValue
        recordingWebcamCorner = SettingKeys.recordingWebcamCorner.defaultValue
        recordingWebcamSize = SettingKeys.recordingWebcamSize.defaultValue
        recordingKeystrokePosition = SettingKeys.recordingKeystrokePosition.defaultValue
        recordingKeystrokeAppearance = SettingKeys.recordingKeystrokeAppearance.defaultValue
        recordingKeystrokeScale = SettingKeys.recordingKeystrokeScale.defaultValue
        recordingClickFilled = SettingKeys.recordingClickFilled.defaultValue
        recordingClickScale = SettingKeys.recordingClickScale.defaultValue
        recordingClickRed = SettingKeys.recordingClickRed.defaultValue
        recordingClickGreen = SettingKeys.recordingClickGreen.defaultValue
        recordingClickBlue = SettingKeys.recordingClickBlue.defaultValue
        recordingCameraDeviceID = SettingKeys.recordingCameraDeviceID.defaultValue
        recordingMicrophoneDeviceID = SettingKeys.recordingMicrophoneDeviceID.defaultValue
        recordingCapturesStudioSession = SettingKeys.recordingCapturesStudioSession.defaultValue
        recordingReconstructsCursor = SettingKeys.recordingReconstructsCursor.defaultValue
        recordingDynamicRange = SettingKeys.recordingDynamicRange.defaultValue
        teleprompterEnabled = SettingKeys.teleprompterEnabled.defaultValue
        teleprompterScript = SettingKeys.teleprompterScript.defaultValue
        teleprompterWordsPerMinute = SettingKeys.teleprompterWordsPerMinute.defaultValue
        teleprompterFontSize = SettingKeys.teleprompterFontSize.defaultValue
        teleprompterMirrored = SettingKeys.teleprompterMirrored.defaultValue
        teleprompterFollowsSpeech = SettingKeys.teleprompterFollowsSpeech.defaultValue
        teleprompterDocksUnderCamera = SettingKeys.teleprompterDocksUnderCamera.defaultValue
        teleprompterFrame = SettingKeys.teleprompterFrame.defaultValue
    }

    private func resetChrome() {
        overlayCorner = SettingKeys.overlayCorner.defaultValue
        overlayCardWidth = SettingKeys.overlayCardWidth.defaultValue
        overlayTimeout = SettingKeys.overlayTimeout.defaultValue
        overlayMaxVisibleCards = SettingKeys.overlayMaxVisibleCards.defaultValue
        overlayOnPrimaryDisplay = SettingKeys.overlayOnPrimaryDisplay.defaultValue
        overlayDismissOnDrag = SettingKeys.overlayDismissOnDrag.defaultValue
        overlayReturnSaves = SettingKeys.overlayReturnSaves.defaultValue
        overlayAlwaysShowActions = SettingKeys.overlayAlwaysShowActions.defaultValue
        lastAllInOneMode = SettingKeys.lastAllInOneMode.defaultValue
        historyRetention = SettingKeys.historyRetention.defaultValue
        historySizeCap = SettingKeys.historySizeCap.defaultValue
        historyIndexesText = SettingKeys.historyIndexesText.defaultValue
        desktopIconsHidden = SettingKeys.desktopIconsHidden.defaultValue
        hideDesktopDuringCapture = SettingKeys.hideDesktopDuringCapture.defaultValue
        hideDesktopDuringRecording = SettingKeys.hideDesktopDuringRecording.defaultValue
        captureWallpaper = SettingKeys.captureWallpaper.defaultValue
        captureWallpaperImagePath = SettingKeys.captureWallpaperImagePath.defaultValue
        includesOverlaysInCaptures = SettingKeys.includesOverlaysInCaptures.defaultValue
    }
}
