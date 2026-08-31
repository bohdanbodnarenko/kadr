import AppKit
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
        Section("Speech") {
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
            switch model.speechStatus {
            case .installed, .none:
                tidyControl
            case .notApplicable:
                if model.dictationSettingsNeeded {
                    Text("Removing filler words needs on-device dictation for this language. "
                        + "Turn it on in System Settings ▸ Keyboard ▸ Dictation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Dictation Settings") {
                        if let url = SpeechDictationSettings.url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    tidyControl
                }
            case .available:
                Text("Removing filler words needs the language model for your language, which "
                    + "this Mac does not have yet. Everything else in the studio works without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                installControl
            case .downloading:
                installControl
            case .unsupported:
                Text("macOS has no speech model for your language, so filler words cannot be "
                    + "found automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.pendingCuts.isEmpty {
                cutReview
            }
            if model.transcript != nil {
                Toggle("Burn in captions", isOn: Binding(
                    get: { model.edit.showsCaptions },
                    set: { value in model.change { $0.showsCaptions = value } }
                ))
            }
        }
        .onChange(of: model.pendingCuts.map(\.id)) {
            largeRemovalArmed = false
        }
    }

    @ViewBuilder
    var tidyControl: some View {
        if model.isTranscribing {
            VStack(alignment: .leading, spacing: 6) {
                if let progress = model.transcriptionProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Listening to the recording…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelTidySpeech() }
                    .controlSize(.small)
            }
        } else {
            Button("Remove filler words and long pauses") {
                Task { await model.tidySpeech() }
            }
            Text("Cuts \u{201C}um\u{201D} and pauses over a second. They become clip boundaries, "
                + "so one undo puts them all back and the recording is never altered.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var cutReview: some View {
        Text("Proposed cuts")
            .font(.callout.weight(.semibold))
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
                Button("Preview") { model.seekToCut(cut) }
                    .controlSize(.small)
            }
        }
        HStack {
            Button(largeRemovalArmed ? "Apply anyway" : "Apply selected") {
                if model.requiresCutConfirmation, !largeRemovalArmed {
                    largeRemovalArmed = true
                    return
                }
                model.applyPendingCuts(confirmingLargeRemoval: largeRemovalArmed)
                largeRemovalArmed = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                largeRemovalArmed = false
                model.discardPendingCuts()
            }
        }
        if model.requiresCutConfirmation {
            Text(largeRemovalArmed
                ? "This would remove more than 40% of the recording. Press Apply anyway to confirm."
                : "This would remove more than 40% of the recording. Press Apply again to confirm.")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    var installControl: some View {
        if let progress = model.installProgress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Button("Cancel download") { model.cancelSpeechModelInstall() }
                    .controlSize(.small)
            }
        } else {
            Button("Download the language model…") { model.installSpeechModel() }
            Text("Downloads Apple's on-device model. It is the only thing in the studio that "
                + "uses the network, it is optional, and your recording is never uploaded — "
                + "the model comes here, the audio stays.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
