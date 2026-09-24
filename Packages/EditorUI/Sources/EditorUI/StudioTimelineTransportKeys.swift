import SwiftUI

/// Home/End, ↑/↓ to edit points, and J/K/L shuttle on the focused timeline
/// (docs/17 T-STU-11).
struct StudioTimelineTransportKeys: ViewModifier {
    let model: StudioDocumentModel

    func body(content: Content) -> some View {
        content
            .onKeyPress(.home) {
                model.seekToStart()
                return .handled
            }
            .onKeyPress(.end) {
                model.seekToEnd()
                return .handled
            }
            .onKeyPress(.upArrow) {
                model.seekToEditPoint(forward: false)
                return .handled
            }
            .onKeyPress(.downArrow) {
                model.seekToEditPoint(forward: true)
                return .handled
            }
            .onKeyPress("j") {
                model.shuttle(.reverse)
                return .handled
            }
            .onKeyPress("k") {
                model.shuttle(.stop)
                return .handled
            }
            .onKeyPress("l") {
                model.shuttle(.forward)
                return .handled
            }
    }
}
