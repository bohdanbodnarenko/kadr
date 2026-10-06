import Foundation
import os
import OSLog
import Shared

/// Builds the diagnostics zip behind Help ▸ Export Diagnostics… and Report a Problem…
/// (docs/17 T-DIAG-1).
///
/// Local and user-initiated end to end: the zip is written into Kadr's own folder and
/// revealed in Finder, and the user decides whether to attach it anywhere. Nothing is
/// uploaded (CLAUDE.md rule 1).
///
/// The zip holds:
/// - `system.json` — `DiagnosticsSnapshot`;
/// - `kadr.log` — the last 24 hours of `com.bohdanbodnarenko.kadr` log entries this process can read;
/// - `DiagnosticReports/` — crash and hang reports for Kadr, the editor and the helper;
/// - `MetricKit/` — the payloads `MetricKitCollector` kept.
nonisolated enum DiagnosticsExporter {
    enum ExportError: LocalizedError {
        case noFolder
        case zipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .noFolder: String(localized: "Kadr could not create a folder for the diagnostics.")
            case let .zipFailed(status): String(localized: "Compressing the diagnostics failed (\(status)).")
            }
        }
    }

    /// The process names whose crash reports belong in a Kadr report.
    static let reportPrefixes = ["Kadr", "KadrEditor", "HelperTools", "kadr"]
    /// How far back logs and crash reports go.
    static let logWindow: TimeInterval = 24 * 60 * 60
    static let reportWindow: TimeInterval = 30 * 24 * 60 * 60

    private static let logger = KadrLog.logger(.app)

    /// `~/Library/Application Support/Kadr/Diagnostics`, shared with MetricKit's payloads.
    nonisolated static func diagnosticsRoot() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support
            .appendingPathComponent("Kadr", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Writes the zip and returns where it is.
    ///
    /// The snapshot is taken on the main actor; everything that touches the disk or the
    /// log store runs detached, because reading a day of logs takes seconds.
    @MainActor
    static func export(snapshot: DiagnosticsSnapshot) async throws -> URL {
        logger.notice("Exporting diagnostics")
        let url = try await Task.detached(priority: .userInitiated) {
            try build(snapshot: snapshot)
        }.value
        logger.notice("Diagnostics written")
        return url
    }

    private nonisolated static func build(snapshot: DiagnosticsSnapshot) throws -> URL {
        let fileManager = FileManager.default
        guard let root = diagnosticsRoot() else { throw ExportError.noFolder }
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
        pruneOldExports(in: exports, keeping: 5)

        let name = "Kadr-Diagnostics-\(fileStamp(Date()))"
        let staging = fileManager.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var snapshot = snapshot
        snapshot.system.freeDiskBytes = freeDiskBytes()
        let sessions = studioSessionUsage()
        snapshot.storage.studioSessionCount = sessions.count
        snapshot.storage.studioSessionBytes = sessions.bytes
        try snapshot.encoded().write(to: staging.appendingPathComponent("system.json"))

        try logText(since: Date().addingTimeInterval(-logWindow))
            .write(to: staging.appendingPathComponent("kadr.log"), atomically: true, encoding: .utf8)

        copyCrashReports(into: staging.appendingPathComponent("DiagnosticReports", isDirectory: true))
        copyMetricKitPayloads(from: root, into: staging.appendingPathComponent("MetricKit", isDirectory: true))

        let zip = exports.appendingPathComponent("\(name).zip")
        try? fileManager.removeItem(at: zip)
        try runDitto(source: staging, destination: zip)
        return zip
    }

    // MARK: - Logs

    /// The log entries this process is allowed to read.
    ///
    /// `OSLogStore.local()` sees every process, which is what a report wants, but it needs
    /// admin rights an ordinary user session does not grant. The fallback sees only this
    /// process — the editor and the helper are missing — and says so at the top, with the
    /// command that collects the rest.
    nonisolated static func logText(since start: Date) -> String {
        let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", KadrLog.subsystem)
        var header = "# Kadr log, \(KadrLog.subsystem), since \(start.ISO8601Format())\n"
        let store: OSLogStore
        if let local = try? OSLogStore.local() {
            store = local
            header += "# scope: every process\n"
        } else if let current = try? OSLogStore(scope: .currentProcessIdentifier) {
            store = current
            header += """
            # scope: the Kadr agent only. For the editor and the helper too, run:
            #   sudo log collect --last 1d --output ~/Desktop/kadr.logarchive
            # and attach the archive.

            """
        } else {
            return header + "# The log store could not be opened.\n"
        }
        do {
            let position = store.position(date: start)
            let entries = try store.getEntries(at: position, matching: predicate)
            var lines = [header]
            for case let entry as OSLogEntryLog in entries {
                lines.append(format(entry))
            }
            return lines.joined(separator: "\n") + "\n"
        } catch {
            return header + "# Reading the log failed: \(error.localizedDescription)\n"
        }
    }

    nonisolated static func format(_ entry: OSLogEntryLog) -> String {
        let level = switch entry.level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "-"
        }
        return "\(entry.date.ISO8601Format()) \(entry.process)[\(entry.processIdentifier)] "
            + "<\(entry.category)> \(level): \(entry.composedMessage)"
    }

    // MARK: - Reports and payloads

    /// Whether a crash or hang report belongs to one of Kadr's processes.
    nonisolated static func isKadrReport(named name: String) -> Bool {
        let lowered = name.lowercased()
        let isReport = lowered.hasSuffix(".ips") || lowered.hasSuffix(".crash")
            || lowered.hasSuffix(".hang") || lowered.hasSuffix(".diag")
        guard isReport else { return false }
        // "Kadr-2026-…", "KadrEditor-…", "HelperTools_…": the process name, then a separator.
        return reportPrefixes.contains { prefix in
            guard name.hasPrefix(prefix) else { return false }
            let rest = name.dropFirst(prefix.count)
            return rest.first.map { $0 == "-" || $0 == "_" || $0 == "." } ?? false
        }
    }

    private nonisolated static func copyCrashReports(into destination: URL) {
        let fileManager = FileManager.default
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        guard let reports = library?.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
              let names = try? fileManager.contentsOfDirectory(atPath: reports.path)
        else { return }
        let cutoff = Date().addingTimeInterval(-reportWindow)
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in names where isKadrReport(named: name) {
            let source = reports.appendingPathComponent(name)
            let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified >= cutoff else { continue }
            try? fileManager.copyItem(at: source, to: destination.appendingPathComponent(name))
        }
    }

    private nonisolated static func copyMetricKitPayloads(from root: URL, into destination: URL) {
        let source = root.appendingPathComponent(MetricKitCollector.folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: - Disk

    private nonisolated static func freeDiskBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private nonisolated static func studioSessionUsage() -> (count: Int, bytes: Int64) {
        guard let root = StudioSessionRecorder.root(),
              let sessions = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return (0, 0) }
        return (sessions.count, sessions.reduce(0) { $0 + directorySize($1) })
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Housekeeping

    /// Old zips are kept only a few deep: each can be tens of megabytes of logs.
    private nonisolated static func pruneOldExports(in folder: URL, keeping count: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lhs > rhs
        }
        for stale in sorted.dropFirst(max(count - 1, 0)) {
            try? fileManager.removeItem(at: stale)
        }
    }

    /// "2026-09-24-1530" — sortable, and legal in a file name on every file system.
    nonisolated static func fileStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = [parts.year, parts.month, parts.day].map { $0 ?? 0 }
        let time = [parts.hour, parts.minute, parts.second].map { $0 ?? 0 }
        return String(format: "%04d-%02d-%02d-", day[0], day[1], day[2])
            + String(format: "%02d%02d%02d", time[0], time[1], time[2])
    }

    /// `ditto` rather than a hand-rolled zip: it is what Finder's Compress uses, so the
    /// result opens with a double-click everywhere.
    private nonisolated static func runDitto(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.zipFailed(process.terminationStatus)
        }
    }
}
