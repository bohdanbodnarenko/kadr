import AnnotationModel
import ControlKit
import StudioSession
import SwiftUI

/// What sits around the recording: a colour, a gradient or a picture (docs/09 U3.5).
@MainActor
extension StudioInspector {
    var canvasSection: some View {
        Section {
            // A segmented control, not four tinted buttons: this is one exclusive choice,
            // and the control macOS has for that reads as a choice at a glance. The label is
            // hidden so four segments get the whole row — at the inspector's narrowest they
            // do not fit beside one, and the section header already says Canvas. VoiceOver
            // still reads the title.
            Picker(String(localized: "Backdrop", bundle: .module), selection: backdropKind) {
                ForEach(StudioBackdropKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            canvasBackdrop
            KadrSlider(
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
            KadrSlider(
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
            KadrSlider(
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
        } header: {
            Text("Canvas", bundle: .module)
        } footer: {
            if case .none = model.edit.canvas.background {
                Text("No backdrop: the recording fills the frame edge to edge.", bundle: .module)
            }
        }
    }

    /// Choosing a kind switches to it — except a wallpaper nobody has picked yet, which asks
    /// for the file first rather than switching to an empty backdrop.
    private var backdropKind: Binding<StudioBackdropKind> {
        Binding(
            get: { model.edit.canvas.background.kind },
            set: { kind in
                if kind == .wallpaper, model.edit.canvas.wallpaperFileName == nil {
                    model.chooseWallpaper()
                } else {
                    model.change { $0.canvas.setBackdropKind(kind) }
                }
            }
        )
    }

    @ViewBuilder
    private var canvasBackdrop: some View {
        switch model.edit.canvas.background {
        case .none:
            EmptyView()
        case let .solid(current):
            canvasSolidSwatches(current: current)
            ColorPicker(String(localized: "Color", bundle: .module), selection: Binding(
                get: { Color(current) },
                set: { color in
                    model.change(coalescingAs: "canvas.fill") { $0.canvas.setSolid(StudioColor(color)) }
                }
            ))
        case let .gradient(ramp):
            canvasGradientSwatches(ramp: ramp)
            gradientStops(ramp: ramp)
            KadrSlider(
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
            HStack {
                Button(String(localized: "Choose Image…", bundle: .module)) { model.chooseWallpaper() }
                Spacer(minLength: 0)
                if model.edit.canvas.wallpaperFileName != nil {
                    Button(String(localized: "Remove", bundle: .module), role: .destructive) { model.removeWallpaper() }
                }
            }
        }
    }

    @ViewBuilder
    private func gradientStops(ramp: StudioGradient) -> some View {
        ColorPicker(String(localized: "From", bundle: .module), selection: gradientStop(ramp: ramp, index: 0))
        if ramp.stops.count > 2 {
            ColorPicker(String(localized: "Middle", bundle: .module), selection: gradientStop(ramp: ramp, index: 1))
        }
        ColorPicker(
            String(localized: "To", bundle: .module),
            selection: gradientStop(ramp: ramp, index: ramp.stops.count - 1)
        )
        Button(ramp.stops.count > 2 ? "Remove Midpoint" : "Add Midpoint") {
            model.change { $0.canvas.setGradient(ramp.togglingMidpoint()) }
        }
    }

    private func gradientStop(ramp: StudioGradient, index: Int) -> Binding<Color> {
        Binding(
            get: { Color(ramp.stops[min(index, ramp.stops.count - 1)]) },
            set: { color in
                var next = ramp
                var stops = next.stops
                stops[min(index, stops.count - 1)] = StudioColor(color)
                next.stops = stops
                model.change(coalescingAs: "canvas.fill") { $0.canvas.setGradient(next) }
            }
        )
    }

    private func canvasSolidSwatches(current: StudioColor) -> some View {
        LazyVGrid(columns: Self.swatchColumns, spacing: 6) {
            ForEach(Array(Self.solidPresets.enumerated()), id: \.offset) { _, color in
                swatch(isSelected: color == current, label: "Canvas color") {
                    model.change { $0.canvas.setSolid(color) }
                } fill: {
                    Color(color)
                }
            }
        }
    }

    private func canvasGradientSwatches(ramp: StudioGradient) -> some View {
        LazyVGrid(columns: Self.swatchColumns, spacing: 6) {
            ForEach(Array(Self.gradientPresets.enumerated()), id: \.offset) { _, preset in
                let selected = preset.0 == ramp.start && preset.1 == ramp.end && ramp.stops.count == 2
                swatch(isSelected: selected, label: "Canvas gradient") {
                    model.change { $0.canvas.setGradient(from: preset.0, to: preset.1) }
                } fill: {
                    LinearGradient(
                        colors: [Color(preset.0), Color(preset.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
    }

    /// One swatch: the selected one wears the accent ring every other macOS colour grid uses.
    private func swatch(
        isSelected: Bool,
        label: String,
        action: @escaping () -> Void,
        @ViewBuilder fill: () -> some ShapeStyle
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Button(action: action) {
            shape
                .fill(fill())
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .overlay {
                    shape
                        .inset(by: -2)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                }
        }
        .buttonStyle(.plain)
        .frame(height: 22)
        .padding(2)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var studioWallpaperRecents: some View {
        let recents = BackdropRecents.load()
        if !recents.isEmpty {
            LabeledContent(String(localized: "Recent", bundle: .module)) {
                HStack(spacing: 6) {
                    ForEach(recents.prefix(4), id: \.self) { path in
                        Button(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) {
                            model.importWallpaper(from: URL(fileURLWithPath: path))
                        }
                        .buttonStyle(.link)
                        .lineLimit(1)
                    }
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
