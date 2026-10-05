import Foundation
import Testing
@testable import KadrEditor

/// The editor's MetricKit files sit beside the agent's without colliding (docs/18 T-DIAG-2).
@Suite("Editor MetricKit files")
struct EditorMetricKitCollectorTests {
    @Test("Names carry the editor prefix and the agent's UTC stamp")
    func fileName() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = EditorMetricKitCollector.fileName(kind: "diagnostics", at: date)
        #expect(name == "editor_diagnostics-2026-09-21-141320.json")
    }

    @Test("Kinds sort by date, not by kind")
    func stampOrdering() {
        let early = EditorMetricKitCollector.fileName(kind: "metrics", at: Date(timeIntervalSince1970: 0))
        let late = EditorMetricKitCollector.fileName(kind: "diagnostics", at: Date(timeIntervalSince1970: 86400))
        #expect(EditorMetricKitCollector.stamp(of: early) < EditorMetricKitCollector.stamp(of: late))
    }
}
