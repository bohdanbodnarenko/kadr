import Foundation
import MetricKit
import os
import Shared

/// Keeps the editor's own crash, hang and resource reports (docs/18 T-DIAG-2).
///
/// The agent's collector only ever hears about the agent: MetricKit reports per process,
/// and the editor — where the heavy rendering and the biggest bitmaps live — was the one
/// process whose hangs nobody kept. Payloads land in the same folder the agent's
/// Export Diagnostics zips, prefixed so the two never prune each other's files. Delivery
/// is on the OS's schedule, at most daily; nothing here runs on a timer, and nothing is
/// sent anywhere (CLAUDE.md rule 1).
final class EditorMetricKitCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = EditorMetricKitCollector()
    /// The prefix on every file this process writes, ahead of the date.
    nonisolated static let prefix = "editor_"
    nonisolated static let fileLimit = 30

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
                "Editor MetricKit: \(crashes, privacy: .public) crash(es), \(hangs, privacy: .public) hang(s)"
            )
        }
    }

    /// `~/Library/Application Support/Kadr/Diagnostics/MetricKit`, the agent's folder.
    nonisolated static func folder() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kadr/Diagnostics/MetricKit", isDirectory: true)
    }

    /// `editor_diagnostics-2026-09-24-153000.json`, in the agent's stamp format (UTC): its
    /// collector sorts by what follows the first dash, so both processes interleave by time.
    nonisolated static func fileName(kind: String, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let values = [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second].map { $0 ?? 0 }
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d%02d", arguments: values)
        return "\(prefix)\(kind)-\(stamp).json"
    }

    /// What follows the first dash: the date, so kinds interleave by time.
    nonisolated static func stamp(of name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return name }
        return String(name[name.index(after: dash)...])
    }

    private nonisolated static func store(_ json: Data, kind: String, at date: Date) {
        guard let folder = folder() else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? json.write(to: folder.appendingPathComponent(fileName(kind: kind, at: date)), options: .atomic)
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        let own = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted { stamp(of: $0) < stamp(of: $1) }
        for name in own.dropLast(fileLimit) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
