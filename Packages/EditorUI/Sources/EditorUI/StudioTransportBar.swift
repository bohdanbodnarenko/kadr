import StudioSession
import SwiftUI

/// Play, cut and undo, as icons on one bar (docs/09 U3.3).
///
/// The studio used to pack labelled buttons — Trim, Split, Delete clip, Speed, Reset clips,
/// Add zoom, Smart zooms, Undo, Redo — into one overflowing row. Screendrop's transport is
/// icons around a centred play control; this is that layout, plus frame-step which that
/// bar does not have.
struct StudioTransportBar: View {
    let model: StudioDocumentModel

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                trimMenu
                speedMenu
                icon("plus.magnifyingglass", help: "Add a zoom at the playhead") {
                    model.addZoom()
                }
                icon("wand.and.stars", help: "Plan zooms from where the recording was clicked") {
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
                icon("scissors", help: "Cut the clip at the playhead (⌘K)") {
                    model.splitAtPlayhead()
                }
                .keyboardShortcut("k", modifiers: .command)
                icon("trash", help: "Delete the selected zoom, or the clip under the playhead") {
                    model.deleteTimelineSelection()
                }
                .disabled(!model.canDeleteTimelineSelection)
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 6)
                icon("arrow.uturn.backward", help: "Undo (⌘Z)") {
                    model.undo()
                }
                // The shortcuts live here as well as on the menu. The menu's `undo:` reaches
                // this model through `StudioWindowController`, which had to be put into the
                // responder chain for it to arrive at all.
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                icon("arrow.uturn.forward", help: "Redo (⇧⌘Z)") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                icon("arrow.counterclockwise", help: "Restore the recording to one uncut clip") {
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
            Text(StudioClock.precise(model.playhead))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            HStack(spacing: 2) {
                icon("backward.end.fill", help: "Go to start") {
                    model.seekToStart()
                }
                icon("gobackward.5", help: "Back 5 seconds (⌥←)") {
                    model.step(seconds: -5)
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                icon("backward.frame", help: "Back one frame (←)") {
                    model.step(frames: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
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
                icon("forward.frame", help: "Forward one frame (→)") {
                    model.step(frames: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                icon("goforward.5", help: "Forward 5 seconds (⌥→)") {
                    model.step(seconds: 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                icon("forward.end.fill", help: "Go to end") {
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
        .disabled(model.playhead <= 0 || model.playhead >= model.edit.duration)
        .help("Drop everything before or after the playhead")
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
    }

    private func icon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(StudioTransportIconStyle())
        .help(help)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))" : String(format: "%.1f", speed)
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
