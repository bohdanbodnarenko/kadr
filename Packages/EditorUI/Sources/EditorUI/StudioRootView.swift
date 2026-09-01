import AnnotationModel
import AppKit
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
    @State private var showsExportOptions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onExport: (StudioDocumentModel) -> Void

    /// The inspector's resting width, and the bounds a drag may move it between.
    ///
    /// Wider than the annotation editor's, because this one carries the timeline's cue list
    /// and a transcript rather than a column of sliders.
    static let inspectorWidth: CGFloat = 320
    static let inspectorMinWidth: CGFloat = 280
    static let inspectorMaxWidth: CGFloat = 460

    public init(model: StudioDocumentModel, onExport: @escaping (StudioDocumentModel) -> Void) {
        _model = State(initialValue: model)
        self.onExport = onExport
    }

    public var body: some View {
        VStack(spacing: 0) {
            StudioPreviewView(model: model)
                .frame(minWidth: 480, minHeight: 270)
            controls
        }
        .frame(maxWidth: .infinity)
        // The system's inspector column, the same one the annotation editor uses.
        //
        // It was an `HStack` with a fixed 320-point panel and a `move` transition — a fair
        // imitation of an inspector right up to the moment somebody tried to drag its edge,
        // which is the first thing anyone does to a panel this size. `NSSplitViewItem`'s
        // inspector behaviour brings the draggable divider, the material, and a collapse
        // animation that matches every other macOS inspector including Xcode's.
        .inspector(isPresented: $isInspectorPresented) {
            sidebar
                .inspectorColumnWidth(
                    min: Self.inspectorMinWidth,
                    ideal: Self.inspectorWidth,
                    max: Self.inspectorMaxWidth
                )
        }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                StudioPresetBar(model: model)
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
            }
            .background(.bar)
        }
        .onAppear { model.applyDefaultPresetIfFresh() }
        .onChange(of: model.exportProgress) { _, progress in
            Self.updateDockProgress(progress)
        }
        .onDisappear { Self.updateDockProgress(nil) }
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
                if model.isCropping {
                    cropBar
                } else {
                    StudioTransportBar(model: model)
                        .frame(maxWidth: .infinity)
                    cropButton
                    inspectorToggle
                    copyButton
                    shareControl
                    exportControl
                }
            }
        }
        .padding(12)
        .background(.bar)
        .onExitCommand {
            if model.isCropping {
                model.cancelCrop()
            }
        }
    }

    private var cropButton: some View {
        Button("Crop") { model.beginCrop() }
            .help("Crop the recording by dragging on the preview")
            .disabled(model.exportProgress != nil)
    }

    private var cropBar: some View {
        HStack(spacing: 8) {
            Text("Crop")
                .font(.headline)
            Picker("Aspect", selection: Binding(
                get: { model.cropAspect },
                set: { model.applyCropAspect($0) }
            )) {
                ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .frame(width: 110)
            Button("Reset") { model.resetWorkingCrop() }
            Spacer()
            Button("Cancel") { model.cancelCrop() }
                .keyboardShortcut(.cancelAction)
            Button("Done") { model.applyCrop() }
                .keyboardShortcut(.defaultAction)
        }
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

    private var copyButton: some View {
        Button("Copy") { model.copyOriginalToClipboard() }
            .help("Copy the original recording. Export first to copy the edit.")
            .disabled(model.exportProgress != nil)
    }

    private var shareControl: some View {
        ShareLink(item: model.session.screenURL) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .labelStyle(.titleOnly)
        .help("Share the original recording. Export first to share the edit.")
        .disabled(model.exportProgress != nil)
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
            Button("Export…") { showsExportOptions = true }
                .keyboardShortcut("e")
                .popover(isPresented: $showsExportOptions, arrowEdge: .top) {
                    StudioExportOptionsView(
                        model: model,
                        onConfirm: {
                            showsExportOptions = false
                            StudioExportSettings.remembered = model.exportSettings
                            onExport(model)
                        },
                        onCancel: { showsExportOptions = false }
                    )
                }
        }
    }

    /// A percent on the Dock icon so an export still reports after the window is covered.
    static func updateDockProgress(_ progress: Double?) {
        if let progress {
            NSApp.dockTile.badgeLabel = "\(Int((progress * 100).rounded()))"
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
        NSApp.dockTile.display()
    }
}
