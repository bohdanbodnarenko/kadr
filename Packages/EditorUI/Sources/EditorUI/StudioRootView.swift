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
            StudioInspector(model: model)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
        .frame(minWidth: 820, minHeight: 520)
        .alert(
            "Studio",
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
        // A second alert rather than one that carries a severity: some of what the studio
        // reports is good news — "removed four passages" — and putting it through the
        // failure path would make every success look like a problem.
        .alert(
            "Studio",
            isPresented: Binding(
                get: { model.notice != nil },
                set: {
                    if !$0 {
                        model.notice = nil
                    }
                }
            )
        ) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    // MARK: - Below the preview

    private var controls: some View {
        VStack(spacing: 8) {
            StudioTimelineView(model: model)
            HStack(spacing: 12) {
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

    private var timeLabel: some View {
        Text("\(format(model.playhead)) / \(format(model.edit.duration))")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var clipButtons: some View {
        HStack(spacing: 8) {
            Button("Split") { model.splitAtPlayhead() }
                .help("Cut the clip at the playhead")
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
            Button("Undo") { model.undo() }
                .disabled(!model.canUndo)
            Button("Redo") { model.redo() }
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
