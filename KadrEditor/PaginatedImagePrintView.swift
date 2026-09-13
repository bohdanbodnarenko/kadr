import AppKit

/// Splits a tall capture across printable pages (CleanShot 4.8, docs/03 §3).
///
/// A scrolling stitch can be tens of thousands of pixels tall; one `NSImageView` on a
/// single sheet shrinks it until it is unreadable. Pagination keeps each band at the
/// printable width and walks down the image.
final class PaginatedImagePrintView: NSView {
    private let image: NSImage
    private let plan: Plan

    struct Plan: Equatable {
        var pageCount: Int
        var sliceHeight: CGFloat
        var pageSize: CGSize
    }

    init(image: NSImage, printInfo: NSPrintInfo) {
        self.image = image
        plan = Self.makePlan(imageSize: image.size, printInfo: printInfo)
        super.init(frame: NSRect(origin: .zero, size: plan.pageSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: plan.pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(origin: .zero, size: plan.pageSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let page = NSPrintOperation.current?.currentPage else { return }
        let index = page - 1
        let sourceY = CGFloat(index) * plan.sliceHeight
        let remaining = image.size.height - sourceY
        let sliceHeight = min(plan.sliceHeight, remaining)
        guard sliceHeight > 0 else { return }

        let source = NSRect(x: 0, y: sourceY, width: image.size.width, height: sliceHeight)
        let destWidth = bounds.width
        let destHeight = sliceHeight * (destWidth / image.size.width)
        let dest = NSRect(x: 0, y: 0, width: destWidth, height: destHeight)
        image.draw(
            in: dest,
            from: source,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    static func makePlan(imageSize: CGSize, printInfo: NSPrintInfo) -> Plan {
        let printable = printInfo.imageablePageBounds.size
        guard imageSize.width > 0, imageSize.height > 0, printable.width > 0, printable.height > 0 else {
            return Plan(pageCount: 1, sliceHeight: max(imageSize.height, 1), pageSize: printable)
        }

        let scale = printable.width / imageSize.width
        let scaledHeight = imageSize.height * scale
        if scaledHeight <= printable.height + 1 {
            return Plan(pageCount: 1, sliceHeight: imageSize.height, pageSize: printable)
        }

        let sliceHeight = printable.height / scale
        let pages = max(1, Int(ceil(imageSize.height / sliceHeight)))
        return Plan(pageCount: pages, sliceHeight: sliceHeight, pageSize: printable)
    }
}
