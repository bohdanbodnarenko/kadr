import CoreGraphics
import Foundation
import StudioSession
import SwiftUI

/// Frames of one clip, decoded lazily for the part of the lane on screen (docs/18 STU-15).
struct ClipFilmstripLane: View {
    let url: URL
    let clip: Clip
    let width: CGFloat
    let height: CGFloat
    /// The lane-local stretch worth drawing, or nil for all of it.
    var visible: ClosedRange<CGFloat>?

    @State private var images: [Int: CGImage] = [:]

    var body: some View {
        let count = StudioFilmstrip.tileCount(forWidth: width, windowed: visible != nil)
        let tile = max(width / CGFloat(count), 1)
        ZStack(alignment: .topLeading) {
            ForEach(images.keys.sorted(), id: \.self) { index in
                if let image = images[index] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: tile, height: height)
                        .clipped()
                        .offset(x: CGFloat(index) * tile)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .task(id: loadKey(count: count)) {
            let indices = StudioTimelineWindow.tileIndices(visible: visible, width: width, count: count)
            guard !indices.isEmpty else {
                images = [:]
                return
            }
            let level = max(Int(log2(Double(max(count, 1))).rounded(.down)), 0)
            // The window in one request, so its missing tiles decode as one batch.
            let tiles = await StudioThumbnailStore.shared.tiles(
                url: url,
                span: .init(start: clip.sourceStart, duration: clip.sourceDuration, level: level),
                requests: indices.map {
                    .init(index: $0, time: StudioFilmstrip.sampleTime(
                        index: $0,
                        count: count,
                        start: clip.sourceStart,
                        duration: clip.sourceDuration
                    ))
                },
                size: CGSize(width: 80, height: 80)
            )
            guard !Task.isCancelled else { return }
            // Only the window is kept, so scrolling a long lane never accumulates frames.
            var decoded: [Int: CGImage] = [:]
            for (offset, image) in tiles.enumerated() {
                if let image {
                    decoded[indices.lowerBound + offset] = image
                }
            }
            images = decoded
        }
    }

    private func loadKey(count: Int) -> String {
        let indices = StudioTimelineWindow.tileIndices(visible: visible, width: width, count: count)
        return "\(clip.id.uuidString)-\(clip.sourceStart)-\(clip.sourceDuration)-\(count)-\(indices)"
    }
}
