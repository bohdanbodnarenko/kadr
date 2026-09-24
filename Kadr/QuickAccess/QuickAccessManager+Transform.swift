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
        // A History copy or the user's own file is never rewritten in place: rotating a
        // library card rewrote the content-addressed blob under its History row
        // (docs/17 T-OUT-5). The card switches to a staged copy of Kadr's own, which is
        // then a capture like any other.
        if !items[index].origin.ownsFile {
            guard let copy = output.adoptCopy(of: items[index].fileURL, named: Self.saveFilename(for: items[index]))
            else {
                presentFeedback(.failure(String(localized: "Couldn't make a copy to edit")))
                return
            }
            items[index].fileURL = copy
            items[index].isStaged = true
            items[index].origin = .capture
            items[index].displayName = nil
        }
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
            presentFeedback(.failure(String(localized: "Couldn't change the capture")))
        }
    }
}
