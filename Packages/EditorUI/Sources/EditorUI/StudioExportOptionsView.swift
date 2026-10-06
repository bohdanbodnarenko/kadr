import MediaExport
import StudioRender
import SwiftUI

/// Quality, codec, resolution, format and audio, asked at the moment of export.
struct StudioExportOptionsView: View {
    @Bindable var model: StudioDocumentModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Options", bundle: .module)
                .font(.headline)

            if model.exportSettings.container == .gif {
                gifControls
            } else {
                movieControls
            }

            labeled("Format") {
                Picker(String(localized: "Format", bundle: .module), selection: $model.exportSettings.container) {
                    ForEach(StudioExportSettings.Container.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text(formatHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let codecWarning {
                Label(codecWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let gifPlanHint {
                Label(gifPlanHint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.exportSettings.container != .gif {
                Toggle(String(localized: "Include audio", bundle: .module), isOn: $model.exportSettings.includeAudio)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Toggle(
                    String(localized: "Wider color (Display P3)", bundle: .module),
                    isOn: $model.exportSettings.widerColor
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(Text(
                    "Keeps a wide-color display's colors. Older players may show them a little dull.",
                    bundle: .module
                ))

                Text(model.exportSettings.sizePreset.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let range = model.marks.range(duration: model.edit.duration) {
                Toggle(isOn: $model.marks.exportsRangeOnly) {
                    let start = StudioInspector.clock(range.lowerBound)
                    let end = StudioInspector.clock(range.upperBound)
                    Text("Only the marked range (\(start)–\(end))", bundle: .module)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if let sizeHint {
                Text(sizeHint)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: .module), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Export", bundle: .module), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Size and rate for a GIF, which has its own because the movie ones do not apply
    /// (docs/17 T-STU-7).
    @ViewBuilder
    private var gifControls: some View {
        labeled("Width") {
            Picker(String(localized: "Width", bundle: .module), selection: $model.exportSettings.gifWidth) {
                ForEach(StudioExportSettings.GIFWidth.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        labeled("Frame rate") {
            Picker(String(localized: "Frame rate", bundle: .module), selection: $model.exportSettings.gifFrameRate) {
                ForEach(StudioExportSettings.GIFFrameRate.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var movieControls: some View {
        labeled("Size") {
            Picker(String(localized: "Size", bundle: .module), selection: $model.exportSettings.sizePreset) {
                ForEach(StudioExportSettings.SizePreset.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }

        labeled("Codec") {
            Picker(String(localized: "Codec", bundle: .module), selection: $model.exportSettings.codec) {
                ForEach(StudioExportSettings.Codec.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        labeled("Resolution") {
            Picker(String(localized: "Resolution", bundle: .module), selection: $model.exportSettings.resolution) {
                ForEach(StudioExportSettings.Resolution.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        labeled("Frame rate") {
            Picker(String(localized: "Frame rate", bundle: .module), selection: $model.exportSettings.frameRate) {
                ForEach(StudioExportSettings.FrameRate.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Where the chosen codec will not do what the user expects (docs/17 T-STU-10).
    private var codecWarning: String? {
        let settings = model.exportSettings
        guard settings.container != .gif else { return nil }
        if settings.container == .mp4, settings.codec == .hevc {
            return "HEVC MP4s don't play in many browsers or on older Windows PCs. Choose H.264 to be safe."
        }
        let natural = StudioRenderPlan.outputSize(
            edit: model.edit,
            sourceSize: model.manifest.pixelSize,
            maxLongestEdge: settings.resolution.maxLongestEdge
        )
        if settings.codec == .h264, max(natural.width, natural.height) > CGFloat(StudioExportSettings.h264MaximumEdge) {
            return "H.264 is limited to \(StudioExportSettings.h264MaximumEdge) px, so this exports at that size. "
                + "Choose HEVC to keep full resolution."
        }
        return nil
    }

    /// What the GIF will really be, when that is less than what was asked for
    /// (docs/17 T-STU-7). The encoder lowers the rate, then the width, and only then cuts
    /// the recording short to stay inside its memory budget — none of which was shown.
    private var gifPlanHint: String? {
        let settings = model.exportSettings
        guard settings.container == .gif else { return nil }
        let size = StudioRenderPlan.outputSize(
            edit: model.edit,
            sourceSize: model.manifest.pixelSize,
            maxLongestEdge: settings.maxLongestEdge
        )
        let plan = settings.gifPlan(outputSize: size, duration: model.edit.duration)
        guard plan.isReduced else { return nil }
        return Self.describe(plan)
    }

    /// "12 fps, 640 px, first 90 s of 4:10" — the plan, in the user's terms.
    static func describe(_ plan: GIFPlan) -> String {
        var parts = ["\(plan.frameRate) fps", "\(plan.maximumWidth) px"]
        if plan.isClipped {
            parts.append("first \(Int(plan.encodedSeconds.rounded(.down))) s of \(Int(plan.sourceSeconds.rounded())) s")
        }
        return "To keep the GIF manageable it will be " + parts.joined(separator: ", ") + "."
    }

    private var formatHint: String {
        switch model.exportSettings.container {
        case .mov:
            "The recording's native format. Best quality on Apple devices."
        case .mp4:
            "Plays on more platforms, including Windows, browsers, and Slack."
        case .gif:
            "An animated GIF of the edited recording. No audio."
        }
    }

    private var sizeHint: String? {
        let settings = model.exportSettings
        let size = StudioRenderPlan.outputSize(
            edit: model.edit,
            sourceSize: model.manifest.pixelSize,
            maxLongestEdge: settings.maxLongestEdge
        )
        guard let bytes = settings.estimatedBytes(
            outputSize: size,
            duration: model.edit.duration,
            manifestFrameRate: model.manifest.frameRate
        ) else {
            return nil
        }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let dimensions = "\(Int(size.width))×\(Int(size.height))"
        return settings.usesCompression
            ? "\(dimensions) · smaller than about \(formatted)"
            : "\(dimensions) · about \(formatted)"
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
