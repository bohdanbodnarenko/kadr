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
    @State private var isInspectorPresented = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onExport: (StudioDocumentModel) -> Void

    public init(model: StudioDocumentModel, onExport: @escaping (StudioDocumentModel) -> Void) {
        _model = State(initialValue: model)
        self.onExport = onExport
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                StudioPreviewView(model: model)
                    .frame(minWidth: 480, minHeight: 270)
                controls
            }
            .frame(maxWidth: .infinity)

            if isInspectorPresented {
                Divider()
                sidebar
                    .frame(width: 320)
                    // Slides in from the edge it lives on rather than appearing, which is
                    // what makes collapsing read as the panel moving out of the way instead
                    // of the window rearranging itself.
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(motion(.snappy(duration: 0.28)), value: isInspectorPresented)
        .frame(minWidth: 820, minHeight: 520)
        .animation(motion(.easeOut(duration: 0.2)), value: model.notice)
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

    /// The inspector and, under it, the transcript once there is one.
    private var sidebar: some View {
        VSplitView {
            StudioInspector(model: model)
                .frame(minHeight: 200)
            if model.transcript != nil {
                StudioTranscriptPanel(model: model)
                    .frame(minHeight: 140)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion(.snappy(duration: 0.3)), value: model.transcript == nil)
    }

    /// Honours Reduce Motion everywhere one animation is asked for.
    ///
    /// A studio is a lot of moving panels, and "smooth" for most people is nausea for some.
    /// One helper rather than an `@Environment` check at every call site, because the check
    /// somebody forgets is the one that matters.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

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
                inspectorToggle
                exportControl
            }
        }
        .padding(12)
        .background(.bar)
    }

    /// Folds the inspector away, the way the annotation editor already does.
    ///
    /// The studio had no way to hide it: the preview is the thing being judged and it was
    /// permanently three hundred points narrower than the window for the sake of controls
    /// nobody is touching while they watch.
    private var inspectorToggle: some View {
        Button {
            isInspectorPresented.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .keyboardShortcut("i", modifiers: .command)
        .help(isInspectorPresented ? "Hide the inspector (⌘I)" : "Show the inspector (⌘I)")
        .accessibilityLabel("Inspector")
        .accessibilityValue(isInspectorPresented ? "Shown" : "Hidden")
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
            Menu("Trim") {
                Button("Trim Start to Playhead") { model.trimStartToPlayhead() }
                Button("Trim End to Playhead") { model.trimEndToPlayhead() }
            }
            .frame(width: 78)
            .disabled(model.playhead <= 0 || model.playhead >= model.edit.duration)
            .help("Drop everything before or after the playhead")
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
