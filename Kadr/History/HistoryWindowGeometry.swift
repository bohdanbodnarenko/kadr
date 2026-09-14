import AppKit

/// The one declared minimum for History (docs/14 UX-20).
enum HistoryWindowGeometry {
    static let minimumWidth: CGFloat = UXLayoutContract.historyMinimum.width
    static let minimumHeight: CGFloat = UXLayoutContract.historyMinimum.height

    static var minimumSize: NSSize {
        NSSize(width: minimumWidth, height: minimumHeight)
    }
}
