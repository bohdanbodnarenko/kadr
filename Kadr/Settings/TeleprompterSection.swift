import ControlKit
import SettingsKit
import Shared
import StudioSession
import SwiftUI

/// The script somebody reads from while recording, and how it behaves (docs/08).
struct TeleprompterSection: View {
    @Bindable var settings: AppSettings
    @State private var installStatus: FeedbackStatus?

    var body: some View {
        Section {
            Toggle("Show a script while recording", isOn: $settings.teleprompterEnabled)

            TextEditor(text: $settings.teleprompterScript)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(alignment: .topLeading) {
                    if settings.teleprompterScript.isEmpty {
                        Text("Type or paste what you plan to say.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, KadrSpace.medium)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(!settings.teleprompterEnabled)

            LabeledContent("Reading time", value: readingTime)

            SettingsValueRow(
                title: "Pace",
                value: $settings.teleprompterWordsPerMinute,
                range: TeleprompterPacing.slowest ... TeleprompterPacing.fastest,
                step: 5,
                format: .wordsPerMinute
            )
            .disabled(!settings.teleprompterEnabled)

            SettingsValueRow(
                title: "Text size",
                value: $settings.teleprompterFontSize,
                range: TeleprompterAppearance.smallestFont ... TeleprompterAppearance.largestFont,
                step: 1,
                format: .screenPoints
            )
            .disabled(!settings.teleprompterEnabled)

            Toggle("Follow my voice", isOn: $settings.teleprompterFollowsSpeech)
                .disabled(!settings.teleprompterEnabled)

            Toggle("Dock under the camera", isOn: $settings.teleprompterDocksUnderCamera)
                .disabled(!settings.teleprompterEnabled)

            Button("Install Speech Model…") {
                Task { await installSpeechModel() }
            }
            .disabled(!settings.teleprompterEnabled || installStatus?.kind == .progress)
            ControlInlineStatus(status: installStatus) {
                installStatus = nil
            }

            Toggle("Mirror the text", isOn: $settings.teleprompterMirrored)
                .disabled(!settings.teleprompterEnabled)
        } header: {
            Text("Teleprompter")
        } footer: {
            Text(
                "Voice follow listens on this Mac only. Without a microphone or speech model, "
                    + "the script scrolls at the pace above."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// How long the script takes at the chosen pace.
    ///
    /// The number a script is actually written against: somebody aiming at a two-minute
    /// video wants to know their script is three, before they record it rather than after.
    private var readingTime: String {
        let script = TeleprompterScript(text: settings.teleprompterScript)
        guard !script.isEmpty else { return "—" }
        let pacing = TeleprompterPacing(wordsPerMinute: settings.teleprompterWordsPerMinute)
        let seconds = Int(pacing.duration(of: script).rounded())
        let words = script.words.count
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(words) words"
    }

    /// User-initiated: never auto-download (CLAUDE.md rule 1).
    ///
    /// Reports progress and the outcome in place: the download takes minutes, and a button
    /// that answered nothing looked broken (docs/18 SH-7).
    private func installSpeechModel() async {
        installStatus = FeedbackStatus(kind: .progress, message: "Installing the speech model…", progress: 0)
        let client = VisionClient()
        defer { client.disconnect() }
        do {
            _ = try await client.installSpeechModel(
                SpeechInstallRequest(localeIdentifier: Locale.current.identifier)
            ) { fraction in
                Task { @MainActor in
                    guard installStatus?.kind == .progress else { return }
                    installStatus?.progress = fraction
                }
            }
            installStatus = .done("The speech model is installed.")
        } catch is CancellationError {
            installStatus = nil
        } catch {
            installStatus = .failure("Kadr could not install the speech model. \(error.localizedDescription)")
        }
    }
}
