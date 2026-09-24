import AppKit
import SettingsKit
import Shared
import SwiftUI

/// The island's strip of controls (docs/03 §1.4).
///
/// Split from `AllInOneHUD` — which owns the panel — so each file is about one thing: the
/// window, or what is drawn in it. Its layout alternatives live in `AllInOneView+Options`
/// and the menus in `AllInOneView+Keys`.
struct AllInOneView: View {
    @Bindable var model: AllInOneModel

    /// Focus has to be *given*, not merely allowed. `focusable()` on its own makes the
    /// island reachable by keyboard navigation and nothing more, so every mode letter and
    /// Esc went nowhere: `onKeyPress` only fires for a view that holds focus.
    @FocusState private var isFocused: Bool

    private static let presetTimerOptions = [0, 3, 5, 10]
    private static let primaryModes: [AllInOneMode] = [.area, .window, .screen, .record]
    static let overflowModes: [AllInOneMode] = [.gif, .scrolling, .ocr, .color]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullStrip
            twoRowStrip
            compactStrip
        }
        .recordingIslandSurface()
        // Focusable so the single-letter mode keys and Esc reach it, but without the system
        // focus ring: on a borderless island it draws a blue rectangle around the whole
        // panel that looks like a rendering bug. The mode buttons keep their own focus
        // treatment for keyboard navigation.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        // A click on the island's own background — anywhere that is not a button — puts
        // the keys back, the way clicking a document window's canvas does.
        .onTapGesture { isFocused = true }
        .onExitCommand { model.cancel() }
        .onKeyPress { press in
            handleKey(press)
        }
        .accessibilityLabel("All-in-One capture")
        // Not a hint: that would also be a system tooltip over the whole island.
        .accessibilityCustomContent("Usage", "Pick a capture mode by its letter, or press Return for the last one.")
        .kadrLayoutDirection()
    }

    private var fullStrip: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            modeButtons(for: AllInOneMode.allCases)
            RecordingBarDivider()
            timerMenu
            aspectMenu
            saveTargetMenu
            recordingAudioMenu
            toolsMenu
            closeButton
        }
    }

    private var twoRowStrip: some View {
        VStack(spacing: RecordingBarMetrics.controlSpacing) {
            HStack(spacing: RecordingBarMetrics.controlSpacing) {
                modeButtons(for: Self.primaryModes)
                overflowMenu
                Spacer(minLength: 0)
                toolsMenu
                closeButton
            }
            HStack(spacing: RecordingBarMetrics.controlSpacing) {
                timerMenu
                aspectMenu
                saveTargetMenu
                recordingAudioMenu
                Spacer(minLength: 0)
            }
        }
    }

    private var compactStrip: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            modeButtons(for: Self.primaryModes)
            overflowMenu
            RecordingBarDivider()
            optionsMenu
            toolsMenu
            closeButton
        }
    }

    private func modeButtons(for modes: [AllInOneMode]) -> some View {
        ForEach(modes, id: \.self) { mode in
            if mode == .screen, NSScreen.screens.count > 1 {
                screenMenu
            } else {
                modeButton(mode)
            }
        }
    }

    private var screenMenu: some View {
        Menu {
            screenTargetRow("Active Display", .activeDisplay)
            ForEach(RecordingDeviceCatalog.displays(), id: \.displayID) { display in
                Button(display.name) {
                    model.onPicked()
                    model.onPickDisplay(display.displayID)
                }
            }
            Divider()
            screenTargetRow("All Displays", .allDisplays)
            screenTargetRow("All Displays, Stitched", .allDisplaysStitched)
        } label: {
            RecordingBarIcon(symbol: AllInOneMode.screen.symbol)
        }
        .recordingBarMenu(tooltip: AllInOneMode.screen.help, key: AllInOneMode.screen.keyCaption)
        .accessibilityLabel(AllInOneMode.screen.title)
    }

    /// One capture with this target. The checkmark marks the Settings default — which is
    /// what the Screen button does — and picking a row never changes it (T-CAP-5).
    private func screenTargetRow(_ title: String, _ target: FullscreenTarget) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.settings.fullscreenTarget == target },
            set: { _ in model.pickScreen(target) }
        ))
    }

    private func modeButton(_ mode: AllInOneMode) -> some View {
        RecordingBarCircleButton(
            symbol: mode.symbol,
            help: mode.help,
            key: mode.keyCaption,
            isOn: true,
            tint: mode == model.lastMode ? Color.accentColor : nil
        ) {
            model.pick(mode)
        }
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(mode == model.lastMode ? .isSelected : [])
    }

    private var closeButton: some View {
        RecordingBarCircleButton(symbol: "xmark", help: "Close", key: "esc") {
            model.cancel()
        }
        .accessibilityLabel("Close")
    }

    var timerOptions: [Int] {
        var options = Self.presetTimerOptions
        let custom = model.settings.customTimerSeconds
        if custom > 0, !options.contains(custom) {
            options.append(custom)
            options.sort()
        }
        return options
    }

    private var timerMenu: some View {
        Menu {
            ForEach(timerOptions, id: \.self) { seconds in
                Button(timerLabel(seconds)) {
                    if seconds == model.settings.customTimerSeconds, seconds > 0 {
                        model.settings.selfTimer = .off
                    } else {
                        model.settings.customTimerSeconds = 0
                        model.settings.selfTimer = SelfTimer(rawValue: seconds) ?? .off
                    }
                }
            }
        } label: {
            RecordingBarIcon(
                symbol: "timer",
                isOn: model.settings.timerSeconds > 0
            )
        }
        .recordingBarMenu(tooltip: timerHelp)
        .accessibilityLabel("Self-timer")
        .accessibilityValue(
            model.settings.timerSeconds > 0
                ? "\(model.settings.timerSeconds) seconds"
                : "Off"
        )
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(CaptureSelectionAspect.allCases, id: \.self) { aspect in
                Button(aspect.title) {
                    model.settings.captureSelectionAspect = aspect
                }
            }
        } label: {
            RecordingBarIcon(
                symbol: model.settings.captureSelectionAspect == .free
                    ? "aspectratio"
                    : "lock.rectangle",
                isOn: model.settings.captureSelectionAspect != .free
            )
        }
        .recordingBarMenu(tooltip: aspectHelp)
        .accessibilityLabel("Aspect lock")
        .accessibilityValue(model.settings.captureSelectionAspect.title)
    }

    private var aspectHelp: String {
        let aspect = model.settings.captureSelectionAspect
        if aspect == .free {
            return "Aspect unlocked — ⇧-drag still squares the selection"
        }
        return "Aspect \(aspect.title) — click to change"
    }

    private var timerHelp: String {
        let seconds = model.settings.timerSeconds
        if seconds == 0 {
            return "Self-timer off — wait before capturing hover states"
        }
        return "Self-timer \(seconds)s — click to change"
    }

    func timerLabel(_ seconds: Int) -> String {
        if seconds == 0 {
            return "No delay"
        }
        if seconds == model.settings.customTimerSeconds, seconds > 0 {
            return "Custom: \(seconds)s"
        }
        return "\(seconds) seconds"
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .return || press.key == .space {
            model.pickLast()
            return .handled
        }
        if let mode = AllInOneMode.matching(shortcut: press.characters) {
            model.pick(mode)
            return .handled
        }
        if let tool = AllInOneTool.matching(shortcut: press.characters) {
            model.use(tool)
            return .handled
        }
        return .ignored
    }
}
