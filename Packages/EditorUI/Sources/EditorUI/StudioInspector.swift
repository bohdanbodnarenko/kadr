import AppKit
import ControlKit
import Foundation
import Shared
import StudioSession
import SwiftUI

/// The studio's controls (docs/09 U3.3–U3.5).
///
/// A segmented control over a grouped form, which is what macOS inspectors of this size look
/// like. Each pane is one question — what is selected, how the picture is framed, what is
/// drawn on it, what it sounds like — and within a pane every group is a plain `Section`
/// with a header and, where something needs saying, a footer. Explanations belong in
/// footers: as body text they read as content, and the eye stops separating the paragraph
/// that matters from the six that do not.
@MainActor
struct StudioInspector: View {
    let model: StudioDocumentModel
    /// Read by `StudioInspector+Speech.swift`: a large removal has to be confirmed twice,
    /// and the confirmation lives in the speech half while the state belongs to the view.
    @State var largeRemovalArmed = false
    @AppStorage("studio.inspector.tab") private var storedTab = StudioInspectorTab.clip.rawValue

    private var tab: StudioInspectorTab {
        StudioInspectorTab(rawValue: storedTab) ?? .clip
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            Form {
                switch tab {
                case .clip: clipPane
                case .frame: framePane
                case .effects: effectsPane
                case .audio: audioPane
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: model.selectedZoom) { _, zoom in reveal(zoom: zoom != nil, clip: false) }
        .onChange(of: model.selectedClip) { _, clip in reveal(zoom: false, clip: clip != nil) }
        .task {
            await model.refreshSpeechStatus()
            model.warmUpSpeech()
        }
    }

    private func reveal(zoom: Bool, clip: Bool) {
        guard let next = StudioInspectorTab.revealing(zoom: zoom, clip: clip) else { return }
        storedTab = next.rawValue
    }

    private var tabPicker: some View {
        Picker("Inspector", selection: Binding(
            get: { tab },
            set: { storedTab = $0.rawValue }
        )) {
            ForEach(StudioInspectorTab.allCases) { pane in
                Text(pane.title)
                    .accessibilityLabel(pane.accessibilityLabel)
                    .tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Panes

    @ViewBuilder
    private var clipPane: some View {
        clipSection
        selectedZoomSection
    }

    @ViewBuilder
    private var framePane: some View {
        lookSection
        shapeSection
        cropSection
        canvasSection
        cameraSection
    }

    @ViewBuilder
    private var effectsPane: some View {
        pointerSection
        clickSection
        zoomMotionSection
        keystrokeSection
    }

    @ViewBuilder
    private var audioPane: some View {
        audioSection
        speechSection
        captionSection
    }

    // MARK: - Clip

    @ViewBuilder
    private var clipSection: some View {
        if let clip = selectedClip {
            Section {
                KadrSlider(
                    title: "Speed",
                    value: Binding(
                        get: { clip.speed },
                        set: { value in model.setSpeed(value, for: clip.id) }
                    ),
                    range: Clip.minimumSpeed ... Clip.maximumSpeed,
                    format: .multiplier
                )
                HStack {
                    Button("Split at Playhead") { model.splitAtPlayhead() }
                    Spacer(minLength: 0)
                    Button("Delete Clip", role: .destructive) { model.removeClipAtPlayhead() }
                        .disabled(model.edit.clips.clips.count < 2)
                }
            } header: {
                Text("Clip \(clipPosition)")
            } footer: {
                Text("Audio stays in sync. Past 8× nothing on screen is readable, so that is the cap.")
            }
        }
    }

    /// "2 of 5" — which cut this is, so the header is not the same word on every clip.
    private var clipPosition: String {
        guard let clip = selectedClip,
              let index = model.edit.clips.clips.firstIndex(where: { $0.id == clip.id })
        else {
            return ""
        }
        return "\(index + 1) of \(model.edit.clips.clips.count)"
    }

    private var selectedClip: Clip? {
        if let id = model.selectedClip {
            return model.edit.clips.clips.first(where: { $0.id == id })
        }
        // `currentClipIndex`, not `clipIndex(at: playhead)`: the form re-renders when the
        // playhead crosses into another clip, not on every playback tick (docs/11 S2).
        guard let index = model.currentClipIndex, model.edit.clips.clips.indices.contains(index) else { return nil }
        return model.edit.clips.clips[index]
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
