import SettingsKit
import SwiftUI

/// Settings → Advanced → URL Scheme: who may drive Kadr through `kadr://`
/// (docs/03 §8.4, docs/17 T-OUT-12).
struct AutomationConsentSection: View {
    @Bindable var consent: AutomationConsent

    init(consent: AutomationConsent = AutomationConsentGate.shared.consent) {
        self.consent = consent
    }

    var body: some View {
        Section("URL Scheme") {
            Toggle("Allow other apps to control Kadr", isOn: $consent.allowsOtherApps)
            Text("Lets apps like Raycast and Alfred run kadr:// commands, which can take "
                + "screenshots and recordings with Kadr's permissions. Each app is asked "
                + "once. The kadr command-line tool and Shortcuts always work. See "
                + "Run `kadr help` in Terminal for every command.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(consent.rememberedApps, id: \.key) { app in
                LabeledContent(app.name) {
                    HStack {
                        Text(app.decision == .allowed ? "Allowed" : "Not allowed")
                            .foregroundStyle(.secondary)
                        Button("Forget") {
                            consent.forget(app.key)
                        }
                        .accessibilityLabel("Forget \(app.name)")
                        .help("\(app.name) will be asked again next time")
                    }
                }
            }
        }
    }
}
