import StudioSession
import SwiftUI

/// Play, cut and undo, as icons on one bar (docs/09 U3.3).
///
/// The studio used to pack labelled buttons — Trim, Split, Delete clip, Speed, Reset clips,
/// Add zoom, Smart zooms, Undo, Redo — into one overflowing row. Screendrop's transport is
/// icons around a centred play control; this is that layout, plus frame-step which that
/// bar does not have.
///
/// The body reads no playhead (docs/11 S2): the clock and the play button's spoken value
/// are leaves that watch the playhead clock, and the trim menu reads a flag the model only
/// writes when it flips.
struct StudioTransportBar: View {
    let model: StudioDocumentModel

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                trimMenu
                speedMenu
                icon("plus.magnifyingglass", label: "Add zoom", help: "Add a zoom at the playhead") {
                    model.addZoom()
                }
                icon("wand.and.stars", label: "Smart zooms", help: "Plan zooms from where the recording was clicked") {
                    model.planSmartZooms()
                }
                Menu {
                    Button("Restore smart zooms") {
                        model.planSmartZooms()
                    }
                    Button("Remove every zoom") {
                        model.resetZooms()
                    }
                    .disabled(model.edit.zooms.isEmpty)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(StudioTransportIconStyle())
                .help("Restore click-planned zooms, or remove every zoom")
                .disabled(model.edit.zooms.isEmpty && model.editedClickTimes.isEmpty)
                Spacer(minLength: 0)
            }

            playback

            HStack(spacing: 2) {
                Spacer(minLength: 0)
                icon("scissors", label: "Split clip", help: "Cut the clip at the playhead (⌘K)") {
                    model.splitAtPlayhead()
                }
                .keyboardShortcut("k", modifiers: .command)
                icon(
                    "trash",
                    label: "Delete selection",
                    help: "Delete the selected zoom, or the clip under the playhead"
                ) {
                    model.deleteTimelineSelection()
                }
                .disabled(!model.canDeleteTimelineSelection)
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 6)
                icon("arrow.uturn.backward", label: "Undo", help: "Undo (⌘Z)") {
                    model.undo()
                }
                // The shortcuts live here as well as on the menu. The menu's `undo:` reaches
                // this model through `StudioWindowController`, which had to be put into the
                // responder chain for it to arrive at all.
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                icon("arrow.uturn.forward", label: "Redo", help: "Redo (⇧⌘Z)") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                icon("arrow.counterclockwise", label: "Reset clips", help: "Restore the recording to one uncut clip") {
                    model.resetClips()
                }
                .disabled(!model.hasClipEdits)
            }
        }
        .frame(height: 32)
        .disabled(model.exportProgress != nil)
    }

    private var playback: some View {
        HStack(spacing: 10) {
            StudioPlayheadClockLabel(clock: model.playheadClock)
            HStack(spacing: 2) {
                icon("backward.end.fill", label: "Go to start", help: "Go to start") {
                    model.seekToStart()
                }
                icon("gobackward.5", label: "Back 5 seconds", help: "Back 5 seconds (⌥←)") {
                    model.step(seconds: -5)
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                icon("backward.frame", label: "Back one frame", help: "Back one frame (←)") {
                    model.step(frames: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                StudioPlayPauseButton(model: model, clock: model.playheadClock)
                icon("forward.frame", label: "Forward one frame", help: "Forward one frame (→)") {
                    model.step(frames: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                icon("goforward.5", label: "Forward 5 seconds", help: "Forward 5 seconds (⌥→)") {
                    model.step(seconds: 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                icon("forward.end.fill", label: "Go to end", help: "Go to end") {
                    model.seekToEnd()
                }
            }
            Text(StudioClock.precise(model.edit.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .disabled(model.edit.duration <= 0)
    }

    private var trimMenu: some View {
        Menu {
            Button("Trim Start to Playhead") { model.trimStartToPlayhead() }
            Button("Trim End to Playhead") { model.trimEndToPlayhead() }
        } label: {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(StudioTransportIconStyle())
        .disabled(!model.playheadIsInsideEdit)
        .help("Drop everything before or after the playhead")
        .accessibilityLabel("Trim clip")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([1.0, 1.5, 2.0, 4.0, 8.0], id: \.self) { speed in
                Button(speed == 1 ? "Normal" : "\(speedLabel(speed))×") {
                    model.setSpeedAtPlayhead(speed)
                }
            }
        } label: {
            Image(systemName: "gauge")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(StudioTransportIconStyle())
        .help("Play this clip faster")
        .accessibilityLabel("Clip speed")
    }

    private func icon(
        _ systemName: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(StudioTransportIconStyle())
        .help(help)
        .accessibilityLabel(label)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))" : String(format: "%.1f", speed)
    }
}

/// The playhead as a clock. A leaf, so a playback tick re-renders one `Text`.
private struct StudioPlayheadClockLabel: View {
    let clock: StudioPlayhead

    var body: some View {
        Text(StudioClock.precise(clock.time))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
    }
}

/// Play and pause, with the playhead as its accessibility value.
///
/// Its own view because that value changes every tick; in the bar it re-rendered every
/// other control with it.
private struct StudioPlayPauseButton: View {
    let model: StudioDocumentModel
    let clock: StudioPlayhead

    var body: some View {
        Button {
            model.togglePlayback()
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        .accessibilityValue(StudioClock.precise(clock.time))
    }
}

/// Playhead and duration as a cuttable clock, not whole seconds.
enum StudioClock {
    static func precise(_ seconds: TimeInterval) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safe) / 60
        let remaining = safe.truncatingRemainder(dividingBy: 60)
        if minutes >= 60 {
            return String(format: "%d:%02d:%04.1f", minutes / 60, minutes % 60, remaining)
        }
        return String(format: "%d:%04.1f", minutes, remaining)
    }
}

private struct StudioTransportIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                .primary.opacity(isEnabled ? (configuration.isPressed ? 0.95 : 0.6) : 0.22)
            )
    }
}
