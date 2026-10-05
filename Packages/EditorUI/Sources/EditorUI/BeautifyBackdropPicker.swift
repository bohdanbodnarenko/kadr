import AnnotationModel
import AppKit
import ControlKit
import SwiftUI
import UniformTypeIdentifiers

/// The curated fills, as swatches (docs/09 U1.1).
///
/// A grid of designed choices in front of the colour wells, because the promise of beautify
/// is a screenshot that looks composed without the user composing it. Someone who wants a
/// specific colour still has the picker underneath; nobody has to invent a gradient.
struct BeautifyBackdropPicker: View {
    /// The current fill, so the chosen swatch can be marked.
    var backdrop: BeautifyBackdrop
    var onChoose: (BeautifyBackdrop) -> Void

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
    private static let swatchHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("None") { onChoose(.none) }
                .buttonStyle(InspectorButtonStyle(fillsWidth: true))
                .accessibilityLabel("No backdrop")
            swatches("Colours", items: BeautifyPalette.solids.map(BeautifyBackdrop.solid))
            swatches("Gradients", items: BeautifyPalette.gradients.map(BeautifyBackdrop.gradient))
            images
            custom
        }
    }

    private func swatches(_ title: String, items: [BeautifyBackdrop]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.inspectorNote)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.columns, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        onChoose(item)
                    } label: {
                        BeautifySwatch(backdrop: item, isSelected: item == backdrop)
                    }
                    .buttonStyle(.plain)
                    .frame(height: Self.swatchHeight)
                    .accessibilityLabel(Self.label(for: item))
                }
            }
        }
    }

    /// The colour wells, for the case the curated set does not cover.
    @ViewBuilder
    private var custom: some View {
        switch backdrop {
        case .none:
            EmptyView()
        case let .solid(colour):
            InspectorColorRow("Custom colour", selection: Binding(
                get: { Color(colour) },
                set: { onChoose(.solid(AnnotationColor($0))) }
            ))
        case let .gradient(ramp):
            InspectorColorRow("From", selection: Binding(
                get: { Color(ramp.start) },
                set: { newValue in
                    var next = ramp
                    next.start = AnnotationColor(newValue)
                    onChoose(.gradient(next))
                }
            ))
            InspectorColorRow("To", selection: Binding(
                get: { Color(ramp.end) },
                set: { newValue in
                    var next = ramp
                    next.end = AnnotationColor(newValue)
                    onChoose(.gradient(next))
                }
            ))
            KadrSlider(
                title: "Angle",
                value: Binding(
                    get: { Double(ramp.angleDegrees) },
                    set: { newValue in
                        var next = ramp
                        next.angleDegrees = CGFloat(newValue)
                        onChoose(.gradient(next))
                    }
                ),
                range: 0 ... 360,
                format: .degrees
            )
        case let .image(path):
            HStack(spacing: 8) {
                Button("Choose Image…") { pickImage() }
                    .buttonStyle(InspectorButtonStyle(fillsWidth: false))
                if !path.isEmpty {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private static func label(for backdrop: BeautifyBackdrop) -> String {
        switch backdrop {
        case .none: "No fill"
        case .solid: "Solid colour"
        case .gradient: "Gradient"
        case .image: "Image"
        }
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Images")
                .font(.inspectorNote)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.columns, spacing: 6) {
                Button(action: pickImage) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(KadrFill.hover, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(KadrFill.stroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .frame(height: Self.swatchHeight)
                .help("Choose an image")
                .accessibilityLabel("Choose an image")

                ForEach(BackdropRecents.load(), id: \.self) { path in
                    Button {
                        onChoose(.image(path: path))
                    } label: {
                        BeautifySwatch(backdrop: .image(path: path), isSelected: backdrop == .image(path: path))
                    }
                    .buttonStyle(.plain)
                    .frame(height: Self.swatchHeight)
                    .accessibilityLabel(URL(fileURLWithPath: path).lastPathComponent)
                }
            }
        }
    }

    /// Opens a local image. There is no catalogue and nothing to download — a wallpaper is
    /// a file the user already has (CLAUDE.md rule 1).
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = BeautifyBackdropPicker.copiedBackdrop(from: url) ?? url.path
        onChoose(.image(path: path))
        BackdropRecents.remember(path)
    }

    /// Copies the chosen image into Application Support so the `.kadr` file does not
    /// depend on a Desktop file the user might later throw away.
    static func copiedBackdrop(from url: URL) -> String? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let folder = support.appendingPathComponent("Kadr/BeautifyBackdrops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination.path
        } catch {
            return nil
        }
    }
}

/// One swatch: the fill it selects, drawn as itself.
struct BeautifySwatch: View {
    var backdrop: BeautifyBackdrop
    var isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
    }

    private var fill: AnyShapeStyle {
        switch backdrop {
        case .none:
            AnyShapeStyle(Color.clear)
        case let .solid(colour):
            AnyShapeStyle(Color(colour))
        case let .gradient(ramp):
            AnyShapeStyle(LinearGradient(
                stops: ramp.stops.map { Gradient.Stop(color: Color($0.color), location: $0.location) },
                startPoint: .top,
                endPoint: .bottom
            ))
        case .image:
            AnyShapeStyle(Color.secondary)
        }
    }
}

/// The nine positions, as a three-by-three grid (docs/09 U1.1).
struct BeautifyAlignmentPicker: View {
    @Binding var alignment: BeautifyAlignment

    private static let rows: [[BeautifyAlignment]] = [
        [.topLeading, .top, .topTrailing],
        [.leading, .center, .trailing],
        [.bottomLeading, .bottom, .bottomTrailing]
    ]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { position in
                        Button {
                            alignment = position
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(position == alignment ? Color.accentColor : Color.primary.opacity(0.08))
                                .frame(width: 18, height: 14)
                        }
                        .buttonStyle(.plain)
                        .help(position.title)
                        .accessibilityLabel(position.title)
                    }
                }
            }
        }
    }
}
