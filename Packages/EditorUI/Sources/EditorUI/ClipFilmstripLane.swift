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
            var frames: [CGImage] = []
            frames.reserveCapacity(times.count)
            for (index, time) in times.enumerated() {
                if Task.isCancelled {
                    return
                }
                if let image = await StudioThumbnailStore.shared.tile(
                    url: url,
                    time: time,
                    level: level,
                    index: index,
                    size: CGSize(width: 80, height: 80)
                ) {
                    frames.append(image)
                }
            }
            images = frames
        }
    }

    private var tileWidth: CGFloat {
        max(width / CGFloat(max(images.count, 1)), 1)
    }

    private var loadKey: String {
        "\(clip.id.uuidString)-\(clip.sourceStart)-\(clip.sourceDuration)-\(StudioFilmstrip.tileCount(forWidth: width))"
    }
}
