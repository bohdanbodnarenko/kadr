import SettingsKit
import StudioSession
import SwiftUI

/// The script somebody reads from while recording, and how it behaves (docs/08).
struct TeleprompterSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Teleprompter") {
            Toggle("Show a script while recording", isOn: $settings.teleprompterEnabled)

            TextEditor(text: $settings.teleprompterScript)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(alignment: .topLeading) {
                    if settings.teleprompterScript.isEmpty {
                        Text("Type or paste what you plan to say.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(!settings.teleprompterEnabled)

            LabeledContent("Reading time", value: readingTime)

            LabeledContent("Pace") {
                Slider(
                    value: $settings.teleprompterWordsPerMinute,
                    in: TeleprompterPacing.slowest ... TeleprompterPacing.fastest,
                    step: 5
                ) {
                    Text("Pace")
                } minimumValueLabel: {
                    Text("Slow")
                } maximumValueLabel: {
                    Text("Fast")
                }
            }
            .disabled(!settings.teleprompterEnabled)

            LabeledContent("Text size") {
                Slider(
                    value: $settings.teleprompterFontSize,
                    in: TeleprompterAppearance.smallestFont ... TeleprompterAppearance.largestFont,
                    step: 1
                )
            }
            .disabled(!settings.teleprompterEnabled)

            Toggle("Follow my voice", isOn: $settings.teleprompterFollowsSpeech)
                .disabled(!settings.teleprompterEnabled)
            Text("Listens on this Mac while you read and keeps your place, instead of "
                + "scrolling at a set pace. Nothing is uploaded, and if there is no "
                + "microphone or no speech model the script simply scrolls at the pace above.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Mirror the text", isOn: $settings.teleprompterMirrored)
                .disabled(!settings.teleprompterEnabled)
            Text("For reading off a beam-splitter glass in front of the camera. "
                + "Drag the panel where you want it while recording; it stays out of the file.")
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
}
