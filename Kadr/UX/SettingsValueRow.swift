import ControlKit
import SwiftUI

/// A numeric Settings row: the label on the leading side, Kadr's slider on the trailing one
/// (docs/14 UX-11).
///
/// The slider is the same control the editor's inspector uses, built once in ControlKit, so
/// a value here reads and enters the same way there: drag the track, click the number to
/// type it, arrow keys step. The label is the row's, so the slider does not draw it again.
/// The value sits inside the slider at a fixed width, so changing it never shifts anything
/// beside it.
struct SettingsValueRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: SliderValueFormat = .percent

    var body: some View {
        LabeledContent(title) {
            KadrSlider(
                title: title,
                value: $value,
                range: range,
                format: format,
                step: step,
                showsTitle: false
            )
            .frame(width: 240)
        }
    }
}
