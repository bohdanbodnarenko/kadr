import AnnotationModel
import StudioSession
import SwiftUI

extension StudioInspector {
    var canvasSection: some View {
        StudioInspectorSection(title: "Canvas", key: "canvas") {
            HStack {
                Button("As recorded") { model.change { $0.canvas = .identity } }
                    .controlSize(.small)
                Button("Presenter") { model.change { $0.canvas = .presenter } }
                    .controlSize(.small)
                Button("Paper") { model.change { $0.canvas = .paper } }
                    .controlSize(.small)
            }
            canvasBackdropKind
            canvasBackdropSwatches
            InspectorSlider(
                title: "Padding",
                value: Binding(
                    get: { model.edit.canvas.paddingFraction },
                    set: { value in
                        model.change(coalescingAs: "canvas.padding") { $0.canvas.paddingFraction = value }
                    }
                ),
                range: 0 ... StudioCanvas.maximumPadding,
                format: .percent
            )
            InspectorSlider(
                title: "Corners",
                value: Binding(
                    get: { model.edit.canvas.cornerRadiusFraction },
                    set: { value in
                        model.change(coalescingAs: "canvas.corners") {
                            $0.canvas.cornerRadiusFraction = value
                        }
                    }
                ),
                range: 0 ... StudioCanvas.maximumCornerRadius,
                format: .percent
            )
            InspectorSlider(
                title: "Shadow",
                value: Binding(
                    get: { model.edit.canvas.shadow },
                    set: { value in
                        model.change(coalescingAs: "canvas.shadow") { $0.canvas.shadow = value }
                    }
                ),
                range: 0 ... 1,
                format: .percent
            )
            Text("A colour, gradient or wallpaper sits around the recording. As recorded is the raw frame.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var canvasBackdropKind: some View {
        HStack(spacing: 6) {
            ForEach(StudioBackdropKind.allCases) { kind in
                Button(kind.title) {
                    if kind == .wallpaper, model.edit.canvas.wallpaperFileName == nil {
                        model.chooseWallpaper()
                    } else {
                        model.change { $0.canvas.setBackdropKind(kind) }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var canvasBackdropSwatches: some View {
        switch model.edit.canvas.background {
        case .none:
            EmptyView()
        case let .solid(current):
            canvasSolidSwatches(current: current)
            ColorPicker(
                "Colour",
                selection: Binding(
                    get: { Color(current) },
                    set: { color in
                        model.change(coalescingAs: "canvas.fill") { $0.canvas.setSolid(StudioColor(color)) }
                    }
                )
            )
        case let .gradient(ramp):
            canvasGradientSwatches(ramp: ramp)
            ColorPicker(
                "From",
                selection: Binding(
                    get: { Color(ramp.start) },
                    set: { color in
                        var next = ramp
                        var stops = next.stops
                        stops[0] = StudioColor(color)
                        next.stops = stops
                        model.change(coalescingAs: "canvas.fill") { $0.canvas.setGradient(next) }
                    }
                )
            )
            ColorPicker(
                "To",
                selection: Binding(
                    get: { Color(ramp.end) },
                    set: { color in
                        var next = ramp
                        var stops = next.stops
                        stops[stops.count - 1] = StudioColor(color)
                        next.stops = stops
                        model.change(coalescingAs: "canvas.fill") { $0.canvas.setGradient(next) }
                    }
                )
            )
            if ramp.stops.count > 2 {
                ColorPicker(
                    "Middle",
                    selection: Binding(
                        get: { Color(ramp.stops[1]) },
                        set: { color in
                            var next = ramp
                            var stops = next.stops
                            stops[1] = StudioColor(color)
                            next.stops = stops
                            model.change(coalescingAs: "canvas.fill") { $0.canvas.setGradient(next) }
                        }
                    )
                )
            }
            Button(ramp.stops.count > 2 ? "Remove midpoint" : "Add midpoint") {
                var next = ramp
                if next.stops.count > 2 {
                    next.stops = [next.start, next.end]
                } else {
                    let mid = StudioColor(
                        red: (next.start.red + next.end.red) / 2,
                        green: (next.start.green + next.end.green) / 2,
                        blue: (next.start.blue + next.end.blue) / 2
                    )
                    next.stops = [next.start, mid, next.end]
                }
                model.change { $0.canvas.setGradient(next) }
            }
            .controlSize(.small)
            InspectorSlider(
                title: "Angle",
                value: Binding(
                    get: { ramp.angleDegrees },
                    set: { value in
                        var next = ramp
                        next.angleDegrees = value
                        model.change(coalescingAs: "canvas.angle") { $0.canvas.setGradient(next) }
                    }
                ),
                range: 0 ... 360,
                format: .degrees
            )
        case .wallpaper:
            studioWallpaperRecents
            Button("Choose Image…") { model.chooseWallpaper() }
                .controlSize(.small)
            if model.edit.canvas.wallpaperFileName != nil {
                Button("Remove wallpaper") { model.removeWallpaper() }
                    .controlSize(.small)
            }
        }
    }

    private func canvasSolidSwatches(current: StudioColor) -> some View {
        LazyVGrid(columns: Self.swatchColumns, spacing: 6) {
            ForEach(Array(Self.solidPresets.enumerated()), id: \.offset) { _, color in
                Button {
                    model.change { $0.canvas.setSolid(color) }
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(color))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(
                                    color == current ? Color.accentColor : Color.primary.opacity(0.12),
                                    lineWidth: color == current ? 2 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .frame(height: 22)
                .accessibilityLabel("Canvas colour")
            }
        }
    }

    private func canvasGradientSwatches(ramp: StudioGradient) -> some View {
        LazyVGrid(columns: Self.swatchColumns, spacing: 6) {
            ForEach(Array(Self.gradientPresets.enumerated()), id: \.offset) { _, preset in
                let selected = preset.0 == ramp.start && preset.1 == ramp.end && ramp.stops.count == 2
                Button {
                    model.change { $0.canvas.setGradient(from: preset.0, to: preset.1) }
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(
                            colors: [Color(preset.0), Color(preset.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(
                                    selected ? Color.accentColor : Color.primary.opacity(0.12),
                                    lineWidth: selected ? 2 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .frame(height: 22)
                .accessibilityLabel("Canvas gradient")
            }
        }
    }

    @ViewBuilder
    private var studioWallpaperRecents: some View {
        let recents = BackdropRecents.load()
        if !recents.isEmpty {
            HStack(spacing: 6) {
                ForEach(recents.prefix(6), id: \.self) { path in
                    Button {
                        model.importWallpaper(from: URL(fileURLWithPath: path))
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.2))
                            .overlay {
                                Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(height: 22)
                    .accessibilityLabel(URL(fileURLWithPath: path).lastPathComponent)
                }
            }
        }
    }

    private static let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    private static let solidPresets: [StudioColor] = BeautifyPalette.solids.map(StudioColor.init)

    private static let gradientPresets: [(StudioColor, StudioColor)] = BeautifyPalette.gradients.map {
        (StudioColor($0.start), StudioColor($0.end))
    }
}
