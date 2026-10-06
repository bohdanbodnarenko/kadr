import AppKit
import ControlKit
import OverlayKit
import SettingsKit
import Shared
import StudioSession
import SwiftUI

/// The script editor opened from the recording bar's teleprompter button.
///
/// Clicking that icon used to flip a setting with no script in reach, so "teleprompter on"
/// meant an empty panel at record time unless somebody had already visited Settings.
/// The composer opens on the bar itself, wired to Kadr's own script, pace and
/// follow-speech settings. Destroyed when hidden (PRD §8).
@MainActor
final class TeleprompterComposer {
    private var panel: NonActivatingPanel?
    private var hosting: NSHostingView<TeleprompterComposerView>?

    var isShowing: Bool {
        panel != nil
    }

    func toggle(settings: AppSettings, above barFrame: NSRect?) {
        if isShowing {
            hide()
        } else {
            show(settings: settings, above: barFrame)
        }
    }

    func show(settings: AppSettings, above barFrame: NSRect?) {
        if let panel {
            panel.setFrameOrigin(origin(for: panel.frame.size, above: barFrame))
            CaptureExclusionRegistry.shared.register(panel)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: TeleprompterComposerView(settings: settings) { [weak self] in
            self?.hide()
        })
        hosting.sizingOptions = .intrinsicContentSize
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.contentView = hosting
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setFrameOrigin(origin(for: hosting.fittingSize, above: barFrame))
        CaptureExclusionRegistry.shared.register(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.hosting = hosting
    }

    func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        hosting = nil
    }

    private func origin(for size: CGSize, above barFrame: NSRect?) -> CGPoint {
        let visible = ActiveScreen.resolve()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let x: CGFloat
        let y: CGFloat
        if let barFrame {
            x = barFrame.midX - size.width / 2
            let placeBelow = barFrame.midY > visible.midY
            y = placeBelow ? barFrame.minY - size.height - 12 : barFrame.maxY + 12
        } else {
            x = visible.midX - size.width / 2
            y = visible.minY + 90
        }
        return CGPoint(
            x: min(max(x, visible.minX + 12), visible.maxX - size.width - 12),
            y: min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
        )
    }
}

struct TeleprompterComposerView: View {
    @Bindable var settings: AppSettings
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            editor
            footer
        }
        .padding(KadrSpace.large)
        .frame(width: 360)
        .background(card)
        .padding(KadrSpace.medium)
        .fixedSize()
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Teleprompter")
                .font(.system(size: KadrType.title, weight: .semibold))
            Spacer()
            Toggle("Show while recording", isOn: $settings.teleprompterEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(
                    settings.teleprompterEnabled
                        ? "The script will appear while you record"
                        : "Turn on to show the script while you record"
                )
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: KadrType.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $settings.teleprompterScript)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(KadrSpace.xs)
            if settings.teleprompterScript.isEmpty {
                Text("Type or paste what you plan to say.")
                    .foregroundStyle(.tertiary)
                    .padding(.top, KadrSpace.large)
                    .padding(.leading, 9)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 140)
        .background(KadrFill.hover, in: RoundedRectangle(cornerRadius: KadrRadius.large, style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(readingTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Pace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                KadrSlider(
                    title: "Pace",
                    value: $settings.teleprompterWordsPerMinute,
                    range: TeleprompterPacing.slowest ... TeleprompterPacing.fastest,
                    format: .wordsPerMinute,
                    step: 5,
                    showsTitle: false
                )
                .frame(width: 140)
                .controlSize(.small)
                .disabled(!settings.teleprompterEnabled)
            }
            HStack(spacing: 8) {
                Toggle("Follow my voice", isOn: $settings.teleprompterFollowsSpeech)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(!settings.teleprompterEnabled)
                Spacer()
                Button("Install Speech Model…") {
                    Task { await installSpeechModel() }
                }
                .controlSize(.small)
                .disabled(!settings.teleprompterEnabled)
            }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.45),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
            .kadrShadow(.floating)
    }

    private var readingTime: String {
        let script = TeleprompterScript(text: settings.teleprompterScript)
        guard !script.isEmpty else { return "No script yet" }
        let seconds = Int(
            TeleprompterPacing(wordsPerMinute: settings.teleprompterWordsPerMinute)
                .duration(of: script)
                .rounded()
        )
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(script.words.count) words"
    }

    private func installSpeechModel() async {
        do {
            _ = try await VisionClient().installSpeechModel(
                SpeechInstallRequest(localeIdentifier: Locale.current.identifier)
            )
        } catch {
            FailurePresenter.present(message: error.localizedDescription)
        }
    }
}
