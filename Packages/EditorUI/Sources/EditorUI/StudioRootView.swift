import AnnotationModel
import AppKit
import ControlKit
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
    @State private var isHoveringNotice = false
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
        .inspector(isPresented: $model.isInspectorPresented) {
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
        .studioExportedBanner(model: model, reduceMotion: reduceMotion)
        .sheet(item: sheetFailure) { failure in
            StudioFailureSheet(failure: failure) { action in
                handleFailureAction(action)
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
                if let action = model.noticeAction {
                    Button(action.title) { model.performNoticeAction(action) }
                        .controlSize(.small)
                }
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(Text("Dismiss", bundle: .module))
            }
            .padding(.horizontal, KadrSpace.large)
            .padding(.vertical, KadrSpace.medium)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KadrRadius.large))
            .overlay(RoundedRectangle(cornerRadius: KadrRadius.large).strokeBorder(.separator))
            .shadow(radius: 6, y: 2)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onHover { isHoveringNotice = $0 }
            .task(id: notice) {
                // Long enough to read a sentence, longer when there is a button to reach,
                // and never while the pointer is on it (docs/14 UX-36).
                try? await Task.sleep(for: .seconds(model.noticeAction == nil ? 4 : 8))
                while isHoveringNotice, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
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

    /// The timeline, then one row of controls — or two, or a compact pair, whichever fits.
    ///
    /// The row used to be a single `HStack` with a `ZStack` transport inside it, and the
    /// crop bar was drawn *over* it on a `.bar` background. At the widths people actually
    /// use with the inspector open, the transport's three groups slid under one another and
    /// the Export group pushed into them; while cropping, the dimmed transport showed
    /// through the edges of the crop bar. Now nothing overlaps: `ViewThatFits` takes the
    /// first arrangement that fits, and crop mode replaces the row instead of covering it.
    private var controls: some View {
        VStack(spacing: 8) {
            StudioTimelineView(model: model)
            Group {
                if model.isCropping {
                    cropBar
                } else if model.isAimingZoom {
                    aimBar
                } else {
                    controlRows
                }
            }
            .frame(minHeight: 36)
        }
        .padding(KadrSpace.large)
        .background(.bar)
        // The transport's keys are not declared here. ⌘K, ⌘I and ⌘E are menu commands and
        // Space and the arrows come through the window's responder chain
        // (`StudioWindowController`), so they work in all three control arrangements and,
        // unlike a bare key equivalent, keep their hands off a focused text field.
        .onExitCommand {
            if model.isCropping {
                model.cancelCrop()
            } else if model.isAimingZoom {
                model.endAimingZoom()
            }
        }
    }

    private var controlRows: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                StudioTransportBar(model: model)
                Divider()
                    .frame(height: 20)
                actions(compact: false)
            }
            VStack(spacing: 8) {
                StudioTransportBar(model: model)
                HStack {
                    Spacer(minLength: 0)
                    actions(compact: false)
                }
            }
            VStack(spacing: 8) {
                StudioTransportBar(model: model, density: .compact)
                HStack {
                    Spacer(minLength: 0)
                    actions(compact: true)
                }
            }
        }
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            cropButton(compact: compact)
            inspectorToggle
            copyButton(compact: compact)
            shareControl(compact: compact)
            exportControl(compact: compact)
        }
        .fixedSize()
    }

    private func cropButton(compact: Bool) -> some View {
        Button {
            model.beginCrop()
        } label: {
            if compact {
                Image(systemName: "crop")
            } else {
                Text("Crop", bundle: .module)
            }
        }
        .help(Text("Crop the recording by dragging on the preview", bundle: .module))
        .accessibilityLabel(Text("Crop", bundle: .module))
        .disabled(model.exportProgress != nil)
    }

    private var cropBar: some View {
        HStack(spacing: 8) {
            Label(String(localized: "Crop", bundle: .module), systemImage: "crop")
                .font(.headline)
            Picker(String(localized: "Aspect", bundle: .module), selection: Binding(
                get: { model.cropAspect },
                set: { model.applyCropAspect($0) }
            )) {
                ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .fixedSize()
            Button(String(localized: "Reset", bundle: .module)) { model.resetWorkingCrop() }
            Spacer(minLength: 8)
            Text("Drag the handles on the preview", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Button(String(localized: "Cancel", bundle: .module)) { model.cancelCrop() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Done", bundle: .module)) { model.applyCrop() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Replaces the transport while a zoom is being aimed on the picture.
    ///
    /// The same shape as the crop bar, because it is the same kind of moment: the preview
    /// has become a place to put something, and the controls that belong to playback would
    /// be answering a different question.
    @ViewBuilder
    private var aimBar: some View {
        if let id = model.aimingZoom, let cue = model.edit.zooms.first(where: { $0.id == id }) {
            HStack(spacing: 8) {
                Label(String(localized: "Aim Zoom", bundle: .module), systemImage: "scope")
                    .font(.headline)
                Button(String(localized: "At the Pointer", bundle: .module)) { model.aimSelectedZoomAtPointer() }
                    .disabled(!model.hasPointerAtPlayhead)
                    .help(Text("Point it where the pointer was when this zoom starts", bundle: .module))
                Button(String(localized: "Center", bundle: .module)) { model.setZoomFocus(id, to: .centre) }
                Spacer(minLength: 8)
                Text(StudioMultiplier.text(cue.magnification))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(String(localized: "Play", bundle: .module)) { model.previewZoom(id) }
                    .help(Text("Watch it from just before it starts", bundle: .module))
                Button(String(localized: "Done", bundle: .module)) { model.endAimingZoom() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help(Text("Keep this aim and go back to the transport (↩)", bundle: .module))
            }
        }
    }

    /// Folds the inspector away, the way the annotation editor already does.
    ///
    /// The studio had no way to hide it: the preview is the thing being judged and it was
    /// permanently three hundred points narrower than the window for the sake of controls
    /// nobody is touching while they watch.
    private var inspectorToggle: some View {
        Button {
            model.isInspectorPresented.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(model.isInspectorPresented ? "Hide the inspector (⌘I)" : "Show the inspector (⌘I)")
        .accessibilityLabel(Text("Inspector", bundle: .module))
        .accessibilityValue(model.isInspectorPresented ? "Shown" : "Hidden")
    }

    private func copyButton(compact: Bool) -> some View {
        Menu {
            Button(String(localized: "Copy (\(StudioExportSettings.sharingSummary))", bundle: .module)) {
                Task { await model.copyEditedToClipboard() }
            }
            Button(String(localized: "Copy Original", bundle: .module)) {
                model.copyOriginalToClipboard()
            }
        } label: {
            if compact {
                Image(systemName: "doc.on.doc")
            } else {
                Text("Copy", bundle: .module)
            }
        }
        .fixedSize()
        .help(Text("Copy the edited recording as \(StudioExportSettings.sharingSummary)", bundle: .module))
        .accessibilityLabel(Text("Copy", bundle: .module))
        .disabled(model.exportProgress != nil)
    }

    private func shareControl(compact: Bool) -> some View {
        Menu {
            Button(String(localized: "Share (\(StudioExportSettings.sharingSummary))", bundle: .module)) {
                Task { await model.shareEdited() }
            }
            ShareLink(item: model.session.screenURL) {
                Text("Share Original", bundle: .module)
            }
        } label: {
            if compact {
                Image(systemName: "square.and.arrow.up")
            } else {
                Text("Share", bundle: .module)
            }
        }
        .fixedSize()
        .background(StudioShareAnchor(model: model))
        .help(Text("Share the edited recording as \(StudioExportSettings.sharingSummary)", bundle: .module))
        .accessibilityLabel(Text("Share", bundle: .module))
        .disabled(model.exportProgress != nil)
    }

    private func exportControl(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let progress = model.exportProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: compact ? 72 : 120)
                // A percent and the time left, not a bar alone (docs/18 STU-13).
                Text(compact ? "\(StudioDocumentModel.exportPercent(progress))%" : model.exportProgressLabel() ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(String(localized: "Cancel", bundle: .module)) {
                    Task { await model.cancelExport() }
                }
                .help(Text("Stop the export and delete the partly-written file", bundle: .module))
            }
            Button(String(localized: "Export…", bundle: .module)) { model.showsExportOptions = true }
                .buttonStyle(.borderedProminent)
                .help(Text("Export the edited recording (⌘E)", bundle: .module))
                .disabled(model.exportProgress != nil)
                .popover(isPresented: $model.showsExportOptions, arrowEdge: .top) {
                    StudioExportOptionsView(
                        model: model,
                        onConfirm: {
                            model.showsExportOptions = false
                            StudioExportSettings.remembered = model.exportSettings
                            onExport(model)
                        },
                        onCancel: { model.showsExportOptions = false }
                    )
                }
        }
    }

    @ViewBuilder
    private var failureBanner: some View {
        if let failure = model.failure, failure.style == .inlineBanner {
            StudioFailureBanner(failure: failure) { action in
                handleFailureAction(action)
            }
            .padding(.top, model.notice == nil ? 10 : 52)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }

    private func handleFailureAction(_ action: StudioFailurePresentation.Action) {
        // Every action answers the banner, so it goes first.
        model.failure = nil
        switch action {
        case .dismiss:
            break
        case let .retry(operation):
            Task { await model.retry(operation) }
        case .confirmLargeCuts:
            model.applyPendingCuts(confirmingLargeRemoval: true)
        case .openSpeechSettings:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            ) {
                NSWorkspace.shared.open(url)
            }
        case .chooseExportLocation:
            model.showsExportOptions = true
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
        // No badge (docs/17 T-STU-12): a red number on the Dock reads as unread items.
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

    /// The app's own icon with a thin bar along the bottom, the way Finder shows a copy
    /// (docs/17 T-STU-12). It used to cover the icon with a dark overlay.
    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds
        NSApp.applicationIconImage?.draw(in: bounds)
        let track = NSRect(x: bounds.minX + 14, y: bounds.minY + 10, width: bounds.width - 28, height: 12)
        let radius = track.height / 2
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var filled = track.insetBy(dx: 2, dy: 2)
        filled.size.width = max(filled.height, filled.width * min(max(progress, 0), 1))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: filled, xRadius: filled.height / 2, yRadius: filled.height / 2).fill()
    }
}
