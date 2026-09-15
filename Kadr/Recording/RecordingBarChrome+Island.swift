import SwiftUI

/// One glass capsule sized to its content, for panels that follow their fitting size
/// (All-in-One). The recording bar builds the same glass inside a fixed panel instead.
struct RecordingIslandSurface<Content: View>: View {
    @State private var tooltip = RecordingBarTooltipModel()
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, RecordingBarMetrics.horizontalPadding)
            .padding(.vertical, (RecordingBarMetrics.barHeight - RecordingBarMetrics.controlSize) / 2)
            .frame(minHeight: RecordingBarMetrics.barHeight)
            .recordingBarGlass()
            .coordinateSpace(.named(RecordingBarCoordinateSpace.bar))
            .overlay { RecordingBarTooltipLayer(tooltip: tooltip) }
            .padding(.top, RecordingBarMetrics.tooltipReserve)
            .padding(RecordingBarMetrics.shadowSlack)
            .fixedSize()
            .environment(tooltip)
    }
}

extension View {
    func recordingIslandSurface() -> some View {
        RecordingIslandSurface { self }
    }
}
