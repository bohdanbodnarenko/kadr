import Foundation
import MetricKit
import os
import Shared

/// Keeps the crash, hang and resource reports macOS hands Kadr (docs/17 T-DIAG-2).
///
/// MetricKit delivers at most once a day, on the OS's schedule: there is no timer here
/// and nothing runs at idle (CLAUDE.md rule 2). Payloads are written as JSON beside the
/// diagnostics exports and travel only inside a zip the user chose to make — MetricKit
/// itself is local on macOS and Kadr sends nothing (rule 1).
///
/// The hang reports are the direct test of the PRD's "no main-thread stalls" posture: a
/// stall long enough for a tester to notice shows up here with a stack.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitCollector()
    /// Under `DiagnosticsExporter.diagnosticsRoot()`.
    nonisolated static let folderName = "MetricKit"
    /// Oldest files go first once there are more than this.
    nonisolated static let fileLimit = 30

    private let logger = KadrLog.logger(.app)
    private var isRegistered = false

    func start() {
        guard !isRegistered else { return }
        isRegistered = true
        MXMetricManager.shared.add(self)
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Self.store(payload.jsonRepresentation(), kind: "metrics", at: payload.timeStampEnd)
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            Self.store(payload.jsonRepresentation(), kind: "diagnostics", at: payload.timeStampEnd)
            KadrLog.logger(.app).notice(
                "MetricKit diagnostics: \(crashes, privacy: .public) crash(es), \(hangs, privacy: .public) hang(s)"
            )
        }
    }

    nonisolated static func folder() -> URL? {
        DiagnosticsExporter.diagnosticsRoot()?.appendingPathComponent(folderName, isDirectory: true)
    }

    private nonisolated static func store(_ json: Data, kind: String, at date: Date) {
        guard let folder = folder() else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(kind)-\(DiagnosticsExporter.fileStamp(date, timeZone: .gmt)).json"
        try? json.write(to: folder.appendingPathComponent(name), options: .atomic)
        prune(folder, keeping: fileLimit)
    }

    /// Names sort by date (`fileStamp`), so the oldest are simply the first.
    nonisolated static func filesToPrune(_ names: [String], keeping limit: Int) -> [String] {
        let sorted = names.filter { $0.hasSuffix(".json") }.sorted { lhs, rhs in
            stamp(of: lhs) < stamp(of: rhs)
        }
        return Array(sorted.dropLast(limit))
    }

    /// The date part of "diagnostics-2026-09-24-153000.json", so metrics and diagnostics
    /// interleave by time rather than by kind.
    private nonisolated static func stamp(of name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return name }
        return String(name[name.index(after: dash)...])
    }

    private nonisolated static func prune(_ folder: URL, keeping limit: Int) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in filesToPrune(names, keeping: limit) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
