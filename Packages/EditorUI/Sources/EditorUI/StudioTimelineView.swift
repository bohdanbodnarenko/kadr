import Foundation
import StudioSession
import SwiftUI

/// The clips, the zooms and the playhead, on one ruler (docs/09 U3.3, U3.4).
///
/// One shared time axis rather than a track per kind. A zoom and the cut it sits inside are
/// related by *when* they are, and separate rulers make somebody compare two scales to see
/// a relationship the eye should get for free.
@MainActor
struct StudioTimelineView: View {
    let model: StudioDocumentModel

    /// The height of the clip band. The cue band sits above it, shorter, because cues are
    /// secondary to the cuts — a zoom over nothing is meaningless, a cut without one is not.
    private let clipHeight: CGFloat = 34
    private let cueHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let scale = width / max(model.edit.duration, 0.001)

            ZStack(alignment: .topLeading) {
                cues(scale: scale)
                clips(scale: scale)
                    .padding(.top, cueHeight + 6)
                playhead(scale: scale, height: geometry.size.height)
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { model.playhead = $0.location.x / scale }
            )
        }
        .frame(height: cueHeight + clipHeight + 6)
    }

    // MARK: - Bands

    private func clips(scale: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(model.edit.clips.clips.enumerated()), id: \.element.id) { index, clip in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(model.clipIndex(at: model.playhead) == index ? 0.55 : 0.3))
                    .frame(width: max(clip.editedDuration * scale - 2, 1), height: clipHeight)
                    .overlay(alignment: .leading) {
                        if clip.speed != 1 {
                            Text(speedLabel(clip.speed))
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 4)
                        }
                    }
            }
        }
    }

    private func cues(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.edit.zooms) { cue in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.orange.opacity(model.selectedZoom == cue.id ? 0.9 : 0.5))
                    .frame(width: max((cue.end - cue.start) * scale, 3), height: cueHeight)
                    .offset(x: cue.start * scale)
                    .onTapGesture { model.selectedZoom = cue.id }
                    .help("\(String(format: "%.1f", cue.magnification))× zoom")
            }
        }
        .frame(height: cueHeight, alignment: .topLeading)
    }

    private func playhead(scale: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 1.5, height: height)
            .offset(x: model.playhead * scale)
            .allowsHitTesting(false)
    }

    /// `2×` rather than `2.0×`: a speed is chosen from a small set and the extra digit is
    /// noise on a label this size.
    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded()
            ? "\(Int(speed))×"
            : String(format: "%.1f×", speed)
    }
}
