import Foundation
import Shared
import Testing
@testable import MediaExport

@Suite("Pasteboard flavour plan")
struct PasteboardFlavorPlanTests {
    @Test("PNG skips its own fallback", arguments: [
        (ImageFormat.png, false, [PasteboardFlavor.native, .tiffFallback]),
        (ImageFormat.png, true, [PasteboardFlavor.native, .tiffFallback, .fileURL]),
        (ImageFormat.jpeg, false, [PasteboardFlavor.native, .pngFallback, .tiffFallback]),
        (ImageFormat.heic, true, [PasteboardFlavor.native, .pngFallback, .tiffFallback, .fileURL]),
        (ImageFormat.webp, false, [PasteboardFlavor.native, .pngFallback, .tiffFallback])
    ])
    func flavorSet(format: ImageFormat, isFinalized: Bool, expected: [PasteboardFlavor]) {
        #expect(PasteboardFlavorPlan.flavors(for: format, isFinalized: isFinalized) == expected)
    }
}
