import AppKit
import MediaExport
import os
import Shared

/// Overlay context-menu transforms (CleanShot §6.2): rotate, flip, Scale Retina to 1×.
@MainActor
extension QuickAccessManager {
    func rotate(_ item: QuickAccessItem) {
        transform(item, .rotateClockwise)
    }

    func flipHorizontal(_ item: QuickAccessItem) {
        transform(item, .flipHorizontal)
    }

    func flipVertical(_ item: QuickAccessItem) {
        transform(item, .flipVertical)
    }

    func scaleRetina(_ item: QuickAccessItem) {
        guard item.canScaleRetina else { return }
        transform(item, .downscaleRetina(item.scale))
    }

    func transform(_ item: QuickAccessItem, _ transform: ImageTransform) {
        guard !item.isVideo else { return }
        finalizeIfStaged(item)
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let url = items[index].fileURL
        do {
            let size = try ImageTransformer().rewrite(url, applying: transform)
            items[index].pixelSize = size
            items[index].contentRevision += 1
            if case .downscaleRetina = transform {
                items[index].scale = .oneToOne
            }
            noteEngagement(with: items[index])
        } catch {
            logger.error("Could not transform overlay capture: \(error.localizedDescription, privacy: .public)")
        }
    }
}
