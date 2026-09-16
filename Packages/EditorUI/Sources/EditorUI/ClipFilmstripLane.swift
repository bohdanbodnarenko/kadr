import CoreGraphics
import Foundation
import StudioSession
import SwiftUI

/// Frames of one clip, decoded lazily as the lane's width changes.
struct ClipFilmstripLane: View {
    let url: URL
    let clip: Clip
    let width: CGFloat
    let height: CGFloat

    @State private var images: [CGImage] = []

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: tileWidth, height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .allowsHitTesting(false)
        .task(id: loadKey) {
            let count = StudioFilmstrip.tileCount(forWidth: width)
            let times = StudioFilmstrip.sampleTimes(
                start: clip.sourceStart,
                duration: clip.sourceDuration,
                count: count
            )
            let level = max(Int(log2(Double(max(count, 1))).rounded(.down)), 0)
            // The whole lane in one request, so its missing tiles decode as one batch.
            let tiles = await StudioThumbnailStore.shared.tiles(
                url: url,
                span: .init(start: clip.sourceStart, duration: clip.sourceDuration, level: level),
                requests: times.enumerated().map { .init(index: $0.offset, time: $0.element) },
                size: CGSize(width: 80, height: 80)
            )
            guard !Task.isCancelled else { return }
            images = tiles.compactMap(\.self)
        }
    }

    private var tileWidth: CGFloat {
        max(width / CGFloat(max(images.count, 1)), 1)
    }

    private var loadKey: String {
        "\(clip.id.uuidString)-\(clip.sourceStart)-\(clip.sourceDuration)-\(StudioFilmstrip.tileCount(forWidth: width))"
    }
}
