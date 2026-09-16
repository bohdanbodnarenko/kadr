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
        .editorLayoutDirection()
        .animation(motion(.easeOut(duration: 0.2)), value: model.notice)
        .overlay(alignment: .top) { banner }
        .overlay(alignment: .top) { failureBanner }
        .sheet(item: sheetFailure) { failure in
            StudioFailureSheet(failure: failure) { action in
                handleFailureAction(action, for: failure)
            }
        }
    }

    private var sheetFailure: Binding<StudioFailurePresentation?> {
        Binding(
            get: { model.failure?.style == .sheet ? model.failure : nil },
            set: {
                if $0 == nil {
                    model.failure = nil
                }
            }
        )
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
            ZStack(alignment: .leading) {
                HStack(spacing: 12) {
                    StudioTransportBar(model: model)
                        .frame(maxWidth: .infinity)
                        .opacity(model.isCropping ? 0.25 : 1)
                        .allowsHitTesting(!model.isCropping)
                    cropButton
                    inspectorToggle
                    copyButton
                    shareControl
                    exportControl
                        .frame(minWidth: 168, alignment: .trailing)
                }
                if model.isCropping {
                    cropBar
                        .background(.bar)
                }
            }
            .frame(minHeight: 36)
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
        Menu {
            Button("Copy") {
                Task { await model.copyEditedToClipboard() }
            }
            Button("Copy Original") {
                model.copyOriginalToClipboard()
            }
        } label: {
            Text("Copy")
        }
        .help("Copy the edited recording shown in the preview")
        .disabled(model.exportProgress != nil)
    }

    private var shareControl: some View {
        Menu {
            Button("Share") {
                Task { await model.shareEdited() }
            }
            ShareLink(item: model.session.screenURL) {
                Text("Share Original")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .labelStyle(.titleOnly)
        .help("Share the edited recording shown in the preview")
        .disabled(model.exportProgress != nil)
    }

    private var exportControl: some View {
        HStack(spacing: 8) {
            if let progress = model.exportProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Button("Cancel") {
                    Task { await model.cancelExport() }
                }
                .help("Stop the export and delete the partly-written file")
            }
            Button("Export…") { showsExportOptions = true }
                .keyboardShortcut("e")
                .disabled(model.exportProgress != nil)
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

    @ViewBuilder
    private var failureBanner: some View {
        if let failure = model.failure, failure.style == .inlineBanner {
            StudioFailureBanner(failure: failure) { action in
                handleFailureAction(action, for: failure)
            }
            .padding(.top, model.notice == nil ? 10 : 52)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }

    private func handleFailureAction(
        _ action: StudioFailurePresentation.Action,
        for failure: StudioFailurePresentation
    ) {
        switch action {
        case .dismiss:
            model.failure = nil
        case .retry:
            model.failure = nil
            if failure.title.contains("40%") {
                model.applyPendingCuts(confirmingLargeRemoval: true)
            }
        case .openSpeechSettings:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            ) {
                NSWorkspace.shared.open(url)
            }
            model.failure = nil
        case .chooseExportLocation:
            model.failure = nil
            showsExportOptions = true
        }
    }

    /// A percent on the Dock icon so an export still reports after the window is covered.
    static func updateDockProgress(_ progress: Double?) {
        StudioDockProgress.update(progress)
    }
}

/// The Dock tile's export progress (docs/16 STU-C6).
///
/// One drawing view, reused, and the tile touched only when the whole percent changes. It
/// used to build a new `NSView`, install it and force a tile `display()` on every progress
/// report — which during a render is every frame.
@MainActor
enum StudioDockProgress {
    private static var view: DockProgressView?
    private static var shownPercent: Int?

    static func update(_ progress: Double?) {
        let tile = NSApp.dockTile
        guard let progress else {
            guard view != nil || shownPercent != nil else { return }
            view = nil
            shownPercent = nil
            tile.contentView = nil
            tile.badgeLabel = nil
            tile.display()
            return
        }
        let percent = Int((min(max(progress, 0), 1) * 100).rounded())
        guard percent != shownPercent else { return }
        shownPercent = percent
        let bar: DockProgressView
        if let view {
            bar = view
        } else {
            bar = DockProgressView(progress: progress)
            bar.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
            view = bar
        }
        bar.progress = progress
        if tile.contentView !== bar {
            tile.contentView = bar
        }
        bar.needsDisplay = true
        tile.badgeLabel = "\(percent)"
        tile.display()
    }
}

/// Local Dock progress drawing (docs/16 STU-C6). No DockProgress package.
private final class DockProgressView: NSView {
    var progress: Double

    init(progress: Double) {
        self.progress = progress
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        dirtyRect.fill()
        let inset = dirtyRect.insetBy(dx: 16, dy: 56)
        NSColor.white.withAlphaComponent(0.25).setFill()
        inset.fill()
        var filled = inset
        filled.size.width = inset.width * min(max(progress, 0), 1)
        NSColor.controlAccentColor.setFill()
        filled.fill()
    }
}
