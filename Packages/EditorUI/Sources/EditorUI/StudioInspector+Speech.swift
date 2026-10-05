import AppKit
import ControlKit
import Foundation
import Shared
import StudioSession
import SwiftUI

/// The inspector's speech half (docs/09 U3.6, docs/13).
///
/// Its own file because it is the only part of the studio that depends on something outside
/// the app — a language model macOS may or may not have, and may have to fetch — so it is
/// mostly a set of states explaining what is missing and what to do about it, while the rest
/// of the inspector is sliders over values that always exist.
@MainActor
extension StudioInspector {
    // MARK: - Speech

    /// Removing filler words and long pauses (docs/09 U3.6).
    ///
    /// The download is a separate control from the tidy-up, deliberately. Merging them
    /// would mean pressing "tidy up" could start a several-hundred-megabyte fetch, which is
    /// not what that button says it does — and on a machine with no network it would be a
    /// button that hangs instead of one that explains.
    var speechSection: some View {
        Section {
            if !model.supportedLocales.isEmpty {
                Picker("Language", selection: Bindable(model).speechLocaleIdentifier) {
                    ForEach(model.supportedLocales, id: \.self) { identifier in
                        Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                            .tag(identifier)
                    }
                }
                .onChange(of: model.speechLocaleIdentifier) {
                    Task { await model.refreshSpeechStatus() }
                }
            }
            speechControl
            if !model.pendingCuts.isEmpty {
                cutReview
            }
        } header: {
            Text("Speech")
        } footer: {
            speechFooter
        }
        .onChange(of: model.pendingCuts.map(\.id)) {
            largeRemovalArmed = false
        }
    }

    @ViewBuilder
    private var speechControl: some View {
        switch model.speechStatus {
        case .installed, .none:
            tidyControl
        case .notApplicable:
            if model.dictationSettingsNeeded {
                Button("Open Dictation Settings") {
                    if let url = SpeechDictationSettings.url {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                tidyControl
            }
        case .available, .downloading:
            installControl
        case .unsupported:
            EmptyView()
        }
    }

    /// One footer per state, because each state has exactly one thing worth saying.
    @ViewBuilder
    private var speechFooter: some View {
        switch model.speechStatus {
        case .notApplicable where model.dictationSettingsNeeded:
            Text("Removing filler words needs on-device dictation for this language. Turn it on in "
                + "System Settings ▸ Keyboard ▸ Dictation.")
        case .available, .downloading:
            Text("Apple's on-device model is the only thing in the studio that uses the network, "
                + "it is optional, and your recording is never uploaded — the model comes here, "
                + "the audio stays.")
        case .unsupported:
            Text("macOS has no speech model for your language, so filler words cannot be found "
                + "automatically.")
        default:
            Text("Finds “um” and shortens pauses over a second to half a second, except where "
                + "you clicked, typed or moved the pointer. Cuts become clip boundaries, so one undo "
                + "puts them all back and the recording is never altered.")
        }
    }

    @ViewBuilder
    var tidyControl: some View {
        if model.isTranscribing {
            LabeledContent("Listening…") {
                HStack(spacing: 8) {
                    if let progress = model.transcriptionProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 90)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Cancel") { model.cancelTidySpeech() }
                        .buttonStyle(.link)
                }
            }
        } else {
            // Filler words are known for a few languages only; elsewhere the toggle would
            // propose nothing (docs/18 STU-10).
            if model.fillerWordsAvailable {
                Toggle("Filler words", isOn: Bindable(model).tidyRemovesFillers)
            }
            Toggle("Long pauses", isOn: Bindable(model).tidyShortensPauses)
            HStack {
                Button("Find Cuts…") {
                    Task { await model.tidySpeech() }
                }
                .disabled(!(model.tidyRemovesFillers && model.fillerWordsAvailable) && !model.tidyShortensPauses)
                Button("Transcribe") {
                    Task { await model.transcribeOnly() }
                }
                .help("Make a transcript for captions, without proposing any cuts")
            }
        }
    }

    @ViewBuilder
    var cutReview: some View {
        ForEach(model.pendingCuts) { cut in
            HStack {
                Toggle(isOn: Binding(
                    get: { model.selectedCutIDs.contains(cut.id) },
                    set: { _ in model.toggleCut(cut.id) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cut.label)
                        Text(Self.clock(cut.start) + " · " + cut.reason.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Preview") { model.seekToCut(cut) }
                    .buttonStyle(.link)
            }
        }
        if model.requiresCutConfirmation {
            Label(
                largeRemovalArmed
                    ? "This removes more than 40% of the recording. Apply anyway to confirm."
                    : "This removes more than 40% of the recording. Apply again to confirm.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.callout)
        }
        HStack {
            Button("Cancel", role: .cancel) {
                largeRemovalArmed = false
                model.discardPendingCuts()
            }
            Spacer(minLength: 0)
            Button(largeRemovalArmed ? "Apply Anyway" : "Apply Selected") {
                if model.requiresCutConfirmation, !largeRemovalArmed {
                    largeRemovalArmed = true
                    return
                }
                model.applyPendingCuts(confirmingLargeRemoval: largeRemovalArmed)
                largeRemovalArmed = false
            }
            // Not the default button (docs/17 T-STU-6): Return pressed for anything else in
            // the studio could apply dozens of cuts the user has not looked at.
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    var installControl: some View {
        if let progress = model.installProgress {
            LabeledContent("Downloading…") {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                    Button("Cancel") { model.cancelSpeechModelInstall() }
                        .buttonStyle(.link)
                }
            }
        } else {
            Button("Download Language Model…") { model.installSpeechModel() }
        }
    }

    // MARK: - Captions

    /// Burned-in captions. Always shown, so captions can be found before a transcript
    /// exists; until then the section offers to make one (docs/18 STU-4).
    @ViewBuilder
    var captionSection: some View {
        if model.transcript == nil {
            Section {
                LabeledContent("Transcribe to add captions") {
                    Button("Transcribe") {
                        Task { await model.transcribeOnly() }
                    }
                    .disabled(model.isTranscribing)
                }
            } header: {
                Text("Captions")
            }
        } else {
            Section {
                Toggle("Burn in captions", isOn: Binding(
                    get: { model.edit.showsCaptions },
                    set: { value in model.change { $0.showsCaptions = value } }
                ))
                if model.edit.showsCaptions {
                    OverlayPlacementPicker(selection: Binding(
                        get: { model.edit.captionPlacement },
                        set: { value in model.change { $0.captionPlacement = value } }
                    ))
                    KadrSlider(
                        title: "Size",
                        value: Binding(
                            get: { model.edit.captionScale },
                            set: { value in
                                model.change(coalescingAs: "caption.scale") { $0.captionScale = value }
                            }
                        ),
                        range: StudioEdit.minimumOverlayScale ... StudioEdit.maximumOverlayScale,
                        format: .multiplier
                    )
                    Toggle("Highlight the spoken word", isOn: Binding(
                        get: { model.edit.highlightsSpokenWord },
                        set: { value in model.change { $0.highlightsSpokenWord = value } }
                    ))
                }
            } header: {
                Text("Captions")
            } footer: {
                if model.edit.showsCaptions {
                    Text("Captions are drawn into the exported movie, not attached as a track.")
                }
            }
        }
    }
}
