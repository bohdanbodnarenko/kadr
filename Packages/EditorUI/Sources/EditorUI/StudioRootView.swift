import Foundation
import StudioSession
import SwiftUI

/// The studio window's contents (docs/09 U3).
///
/// Preview above, timeline below, inspector beside. The preview is the largest thing on
/// screen because it is what the user is judging; everything else exists to change it.
@MainActor
public struct StudioRootView: View {
    @State private var model: StudioDocumentModel
    private let onExport: (StudioDocumentModel) -> Void

    public init(model: StudioDocumentModel, onExport: @escaping (StudioDocumentModel) -> Void) {
        _model = State(initialValue: model)
        self.onExport = onExport
    }

    public var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                StudioPreviewView(model: model)
                    .frame(minWidth: 480, minHeight: 270)
                Divider()
                controls
            }
            VSplitView {
                StudioInspector(model: model)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                if model.transcript != nil {
                    StudioTranscriptPanel(model: model)
                        .frame(minHeight: 140)
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
        }
        .frame(minWidth: 820, minHeight: 520)
        .animation(.easeOut(duration: 0.18), value: model.notice)
        .overlay(alignment: .top) { banner }
        // A failure still stops the user, because it means the thing they asked for did not
        // happen. Everything else is a banner (docs/08 §2 item 13).
        .alert(
            "The studio could not do that",
            isPresented: Binding(
                get: { model.failure != nil },
                set: {
                    if !$0 {
                        model.failure = nil
                    }
                }
            )
        ) {
            Button("OK") { model.failure = nil }
        } message: {
            Text(model.failure ?? "")
        }
    }

    /// Good news, and news that changes nothing the user has to decide.
    ///
    /// Both used to be modal alerts titled "Studio" with an OK button — so finishing a tidy
    /// pass stopped the app dead to announce "Removed 4 passages", and the user dismissed a
    /// dialog to get back to the work they could already see had happened. A banner says the
    /// same thing without taking the keyboard away, and leaves on its own.
    @ViewBuilder
    private var banner: some View {
        if let notice = model.notice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                Text(notice)
                    .font(.callout)
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .shadow(radius: 6, y: 2)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notice) {
                // Long enough to read a sentence, and it does not block anything meanwhile.
                try? await Task.sleep(for: .seconds(4))
                if model.notice == notice {
                    model.notice = nil
                }
            }
        }
    }

    // MARK: - Below the preview

    private var controls: some View {
        VStack(spacing: 8) {
            StudioTimelineView(model: model)
            HStack(spacing: 12) {
                transport
                timeLabel
                Divider().frame(height: 16)
                clipButtons
                Divider().frame(height: 16)
                zoomButtons
                Spacer()
                exportControl
            }
        }
        .padding(12)
    }

    /// Play, and step a frame either way (docs/08 §2 item 10).
    ///
    /// Visible buttons rather than key handling alone, and every one of them carries the
    /// shortcut on its own label: a studio whose only transport is a keystroke nobody
    /// mentioned is a studio people scrub frame by frame forever.
    private var transport: some View {
        HStack(spacing: 4) {
            Button {
                model.step(frames: -1)
            } label: {
                Image(systemName: "backward.frame")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Back one frame (←)")

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")

            Button {
                model.step(frames: 1)
            } label: {
                Image(systemName: "forward.frame")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Forward one frame (→)")
        }
        .disabled(model.edit.duration <= 0)
    }

    private var timeLabel: some View {
        Text("\(format(model.playhead)) / \(format(model.edit.duration))")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var clipButtons: some View {
        HStack(spacing: 8) {
            Button("Split") { model.splitAtPlayhead() }
                .keyboardShortcut("k", modifiers: .command)
                .help("Cut the clip at the playhead (⌘K)")
            Button("Delete clip") { model.removeClipAtPlayhead() }
                .disabled(model.edit.clips.clips.count < 2)
            Menu("Speed") {
                ForEach([1.0, 1.5, 2.0, 4.0, 8.0], id: \.self) { speed in
                    Button(speed == 1 ? "Normal" : "\(format(speed: speed))×") {
                        model.setSpeedAtPlayhead(speed)
                    }
                }
            }
            .frame(width: 90)
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 8) {
            Button("Add zoom") { model.addZoom() }
            Button("Smart zooms") { model.planSmartZooms() }
                .help("Plan zooms from where the recording was clicked")
            // The shortcuts live here as well as on the menu. The menu's `undo:` reaches
            // this model through `StudioWindowController`, which had to be put into the
            // responder chain for it to arrive at all — before that, ⌘Z did nothing in the
            // studio while an Undo button sat next to it doing something.
            Button("Undo") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
    }

    @ViewBuilder
    private var exportControl: some View {
        if let progress = model.exportProgress {
            // A ten-minute recording takes minutes to render, and without this the only way
            // out was ⌘Q — which killed the process mid-write and left the partial file at
            // the destination the user had chosen (docs/11 S0.4).
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Button("Cancel") {
                    Task { await model.cancelExport() }
                }
                .help("Stop the export and delete the partly-written file")
            }
        } else {
            Button("Export…") { onExport(model) }
                .keyboardShortcut("e")
        }
    }

    // MARK: - Formatting

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func format(speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))" : String(format: "%.1f", speed)
    }
}
