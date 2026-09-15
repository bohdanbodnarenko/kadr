import SwiftUI

/// Quality, codec, resolution, format and audio, asked at the moment of export.
struct StudioExportOptionsView: View {
    @Bindable var model: StudioDocumentModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Options")
                .font(.headline)

            labeled("Quality") {
                Picker("Quality", selection: $model.exportSettings.quality) {
                    ForEach(StudioExportSettings.Quality.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeled("Codec") {
                Picker("Codec", selection: $model.exportSettings.codec) {
                    ForEach(StudioExportSettings.Codec.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(model.exportSettings.container == .gif)

            labeled("Resolution") {
                Picker("Resolution", selection: $model.exportSettings.resolution) {
                    ForEach(StudioExportSettings.Resolution.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeled("Format") {
                Picker("Format", selection: $model.exportSettings.container) {
                    ForEach(StudioExportSettings.Container.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeled("Frame rate") {
                Picker("Frame rate", selection: $model.exportSettings.frameRate) {
                    ForEach(StudioExportSettings.FrameRate.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(model.exportSettings.container == .gif)

            Text(formatHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include audio", isOn: $model.exportSettings.includeAudio)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.exportSettings.container == .gif)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var formatHint: String {
        switch model.exportSettings.container {
        case .mov:
            "The recording's native format. Best quality on Apple devices."
        case .mp4:
            "Plays on more platforms, including Windows, browsers, and Slack."
        case .gif:
            "An animated GIF of the edited recording. No audio. Caps at 800 px so the file stays shareable."
        }
    }

    private func labeled(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            control()
        }
    }
}
