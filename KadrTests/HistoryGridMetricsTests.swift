import Foundation
import Testing
@testable import Kadr

@Suite("History grid metrics")
struct HistoryGridMetricsTests {
    @Test("Column count follows the window, not a 560 pt assumption", arguments: [
        (width: CGFloat(400), expected: 2),
        (width: CGFloat(720), expected: 4),
        (width: CGFloat(1000), expected: 6)
    ])
    func columnsForWidths(width: CGFloat, expected: Int) {
        #expect(HistoryGridMetrics.columns(forWindowWidth: width) == expected)
    }
}
