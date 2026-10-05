import ControlKit
import StudioSession
import SwiftUI

/// Play, cut and undo, as icons on one bar (docs/09 U3.3).
///
/// The studio used to pack labelled buttons — Trim, Split, Delete clip, Speed, Reset clips,
/// Add zoom, Smart zooms, Undo, Redo — into one overflowing row. This is icons around a
/// centred play control, plus frame-step.
///
/// Three columns, never a `ZStack`. The bar used to overlay the edit tools, the playback
/// controls and the cut tools on top of each other and rely on spacers to keep them apart,
/// so as soon as the preview column narrowed — the inspector open, a smaller window — they
/// slid under one another. Now each column keeps its own width, and `StudioRootView`
/// picks the `.compact` density when even that does not fit.
///
/// No keyboard shortcuts here: the root offers several layouts and only one is on screen,
/// so the keys live once in `StudioTransportShortcuts` and keep working whichever it is.
///
/// The body reads no playhead (docs/11 S2): the clock and the play button's spoken value
/// are leaves that watch the playhead clock, and the trim menu reads a flag the model only
/// writes when it flips.
struct StudioTransportBar: View {
    enum Density {
        /// Every tool as its own icon, playback centred between them.
        case regular
        /// The edit tools in one menu, playback without the five-second and end jumps.
        case compact
    }

    let model: StudioDocumentModel
    var density: Density = .regular

    var body: some View {
        Group {
            switch density {
            case .regular:
                HStack(spacing: 8) {
                    editTools
                        .frame(maxWidth: .infinity, alignment: .leading)
                    playback(compact: false)
                        .fixedSize()
                    cutTools
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .compact:
                HStack(spacing: 8) {
                    editMenu
                    undoRedo
                    Spacer(minLength: 8)
                    playback(compact: true)
                        .fixedSize()
                }
            }
        }
        .frame(height: 32)
        .disabled(model.exportProgress != nil)
    }

    // MARK: - Columns

    private var editTools: some View {
        HStack(spacing: 2) {
            trimMenu
            speedMenu
            // Named, not just a magnifier: this is the one control whose purpose people
            // could not guess, and the thing they most want to do by hand.
            Button {
                model.pausePlayback()
                model.addOrSelectZoom(at: model.playhead)
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(StudioTransportIconStyle())
            .fixedSize()
            .help("Add a zoom at the playhead (Z at the pointer, or click the zoom lane)")
            .accessibilityLabel("Add zoom")
            StudioSuggestedZoomsButton(model: model)
            Menu {
                zoomMenuItems
            } label: {
                iconLabel("ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(StudioTransportIconStyle())
            .fixedSize()
            .help("More zoom actions")
            .accessibilityLabel("More zoom actions")
        }
    }

    private var cutTools: some View {
        HStack(spacing: 2) {
            icon("scissors", label: "Split clip", help: "Cut the clip at the playhead (⌘K)") {
                model.splitAtPlayhead()
            }
            icon(
                "trash",
                label: "Delete selection",
                help: "Delete the selected zoom or clip (Delete)"
            ) {
                model.deleteTimelineSelection()
            }
            .disabled(!model.canDeleteTimelineSelection)
            separator
            undoRedo
            icon("arrow.counterclockwise", label: "Reset clips", help: "Restore the recording to one uncut clip") {
                model.resetClips()
            }
            .disabled(!model.hasClipEdits)
        }
    }

    private var undoRedo: some View {
        HStack(spacing: 2) {
            icon("arrow.uturn.backward", label: "Undo", help: "Undo (⌘Z)") {
                model.undo()
            }
            .disabled(!model.canUndo)
            icon("arrow.uturn.forward", label: "Redo", help: "Redo (⇧⌘Z)") {
                model.redo()
            }
            .disabled(!model.canRedo)
        }
    }

    /// Every edit tool in one place, for a bar with no room for a row of icons.
    private var editMenu: some View {
        Menu {
            Button("Split Clip at Playhead") { model.splitAtPlayhead() }
            Button("Delete Selection") { model.deleteTimelineSelection() }
                .disabled(!model.canDeleteTimelineSelection)
            Divider()
            Button("Trim Start to Playhead") { model.trimStartToPlayhead() }
                .disabled(!model.playheadIsInsideEdit)
            Button("Trim End to Playhead") { model.trimEndToPlayhead() }
                .disabled(!model.playheadIsInsideEdit)
            Menu("Clip Speed") { speedItems }
            Button("Reset Clips") { model.resetClips() }
                .disabled(!model.hasClipEdits)
            Divider()
            Button("Add Zoom at Playhead") { model.addOrSelectZoom(at: model.playhead) }
            zoomMenuItems
        } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Split, trim, speed and zoom")
    }

    private func playback(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            StudioPlayheadClockLabel(clock: model.playheadClock, frameRate: model.manifest.frameRate)
            HStack(spacing: 2) {
                if !compact {
                    icon("backward.end.fill", label: "Go to start", help: "Go to start") {
                        model.seekToStart()
                    }
                    icon("gobackward.5", label: "Back 5 seconds", help: "Back 5 seconds (⌥←)") {
                        model.step(seconds: -5)
                    }
                }
                icon("backward.frame", label: "Back one frame", help: "Back one frame (←)") {
                    model.step(frames: -1)
                }
                StudioPlayPauseButton(model: model, clock: model.playheadClock)
                icon("forward.frame", label: "Forward one frame", help: "Forward one frame (→)") {
                    model.step(frames: 1)
                }
                if !compact {
                    icon("goforward.5", label: "Forward 5 seconds", help: "Forward 5 seconds (⌥→)") {
                        model.step(seconds: 5)
                    }
                    icon("forward.end.fill", label: "Go to end", help: "Go to end") {
                        model.seekToEnd()
                    }
                }
            }
            Text(StudioClock.frames(model.edit.duration, frameRate: model.manifest.frameRate))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .disabled(model.edit.duration <= 0)
    }

    // MARK: - Pieces

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var zoomMenuItems: some View {
        let suggested = model.zoomSuggestions.count
        Button(suggested > 0 ? "Add \(suggested) Suggested Zooms" : "Add Suggested Zooms") {
            model.addSuggestedZooms()
        }
        .disabled(suggested == 0)
        Button("Previous Zoom  [") { model.selectAdjacentZoom(forward: false) }
            .disabled(model.edit.zooms.isEmpty)
        Button("Next Zoom  ]") { model.selectAdjacentZoom(forward: true) }
            .disabled(model.edit.zooms.isEmpty)
        Divider()
        Toggle("Show Suggested Zooms", isOn: Binding(
            get: { model.showsZoomSuggestions },
            set: { model.showsZoomSuggestions = $0 }
        ))
        Button("Replace All with Smart Zooms") { model.planSmartZooms() }
            .disabled(model.editedClickTimes.isEmpty)
        Button("Remove Every Zoom", role: .destructive) { model.resetZooms() }
            .disabled(model.edit.zooms.isEmpty)
    }

    private var trimMenu: some View {
        Menu {
            Button("Trim Start to Playhead") { model.trimStartToPlayhead() }
            Button("Trim End to Playhead") { model.trimEndToPlayhead() }
        } label: {
            iconLabel("arrow.left.and.right")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(StudioTransportIconStyle())
        .fixedSize()
        .disabled(!model.playheadIsInsideEdit)
        .help("Drop everything before or after the playhead")
        .accessibilityLabel("Trim clip")
    }

    private var speedMenu: some View {
        Menu {
            speedItems
        } label: {
            iconLabel("gauge")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(StudioTransportIconStyle())
        .fixedSize()
        .help("Play this clip faster")
        .accessibilityLabel("Clip speed")
    }

    private var speedItems: some View {
        ForEach([1.0, 1.5, 2.0, 4.0, 8.0], id: \.self) { speed in
            Button(speed == 1 ? "Normal" : "\(speedLabel(speed))×") {
                model.setSpeedAtPlayhead(speed)
            }
        }
    }

    private func iconLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 24)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func icon(
        _ systemName: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            iconLabel(systemName)
        }
        .buttonStyle(StudioTransportIconStyle())
        .help(help)
        .accessibilityLabel(label)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))" : String(format: "%.1f", speed)
    }
}

/// Adds every suggested zoom, with a count so the lane's outlines have a name.
private struct StudioSuggestedZoomsButton: View {
    let model: StudioDocumentModel

    var body: some View {
        let count = model.zoomSuggestions.count
        Button {
            model.addSuggestedZooms()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(min(count, 99))")
                            .font(KadrType.numeric(KadrType.micro, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Color.orange))
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(StudioTransportIconStyle())
        .disabled(count == 0)
        .help(count > 0
            ? "Add the \(count) suggested zooms from your clicks. Your own zooms stay."
            : "No suggested zooms: every click cluster already has one")
        .accessibilityLabel("Add suggested zooms")
        .accessibilityValue("\(count)")
    }
}

/// The playhead as a clock. A leaf, so a playback tick re-renders one `Text`.
private struct StudioPlayheadClockLabel: View {
    let clock: StudioPlayhead
    let frameRate: Int

    var body: some View {
        Text(StudioClock.frames(clock.time, frameRate: frameRate))
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

    /// `mm:ss:ff` — minutes, seconds and the frame within the second (docs/17 T-STU-11).
    ///
    /// Frames, not tenths, because a frame is the unit a cut is made in: two frames a
    /// tenth apart read the same in tenths and are a visible jump in the picture.
    static func frames(_ seconds: TimeInterval, frameRate: Int) -> String {
        let fps = max(frameRate, 1)
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let totalFrames = Int((safe * Double(fps)).rounded(.down))
        let frame = totalFrames % fps
        let wholeSeconds = totalFrames / fps
        let minutes = wholeSeconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d:%02d", minutes / 60, minutes % 60, wholeSeconds % 60, frame)
        }
        return String(format: "%02d:%02d:%02d", minutes, wholeSeconds % 60, frame)
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
