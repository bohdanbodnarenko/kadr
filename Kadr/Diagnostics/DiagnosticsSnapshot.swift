import AppKit
import Foundation

/// The `system.json` in a diagnostics zip, and the text behind Copy Diagnostic Summary
/// (docs/17 T-DIAG-1).
///
/// Everything here is about the Mac and the build, never about what the user captured:
/// no file names, no window titles, and every path shortened to `~` so the account name
/// does not travel with a report. It is written to disk and handed to the user; nothing
/// here is sent anywhere (CLAUDE.md rule 1).
nonisolated struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        var version: String
        var build: String
        var commit: String?
        var bundlePath: String
        var runLocation: RunLocation
    }

    struct System: Codable, Equatable, Sendable {
        var macOS: String
        var osBuild: String
        var hardwareModel: String
        var architecture: String
        var isTranslated: Bool
        var freeDiskBytes: Int64?
    }

    struct Display: Codable, Equatable, Sendable {
        var id: UInt32
        /// In global AppKit points, bottom-left origin — the arrangement as AppKit sees it.
        var frame: [Double]
        var scale: Double
        var isPrimary: Bool
        var hasNotch: Bool
    }

    struct Storage: Codable, Equatable, Sendable {
        var studioSessionCount: Int
        var studioSessionBytes: Int64
        var historyItemCount: Int
    }

    var generatedAt: Date
    var app: App
    var system: System
    var displays: [Display]
    /// `AppPermission.rawValue` → a status label.
    var permissions: [String: String]
    /// `CaptureCommand.rawValue` → why the shortcut could not be registered.
    var hotkeyConflicts: [String: String]
    var loginItem: String
    /// Every key Kadr has written to its preferences, values shortened with `~`.
    var settings: [String: String]
    var storage: Storage

    /// Pretty, key-sorted JSON: a diff of two testers' files should show only what differs.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    var summaryText: String {
        (try? encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

// MARK: - Where the app is running from

/// Where the running bundle lives (docs/17 T-SH-2).
///
/// Running from the disk image or from a translocated copy breaks the login item, Sparkle's
/// in-place update, the CLI link and the permission grants, which attach to a path that
/// later changes. It is the first thing to know about a report that says "it forgot".
nonisolated enum RunLocation: String, Codable, Equatable, Sendable {
    case applications
    case userApplications
    case diskImage
    case translocated
    case buildProducts
    case other

    static func classify(bundlePath path: String, home: String = NSHomeDirectory()) -> RunLocation {
        if path.contains("/AppTranslocation/") {
            return .translocated
        }
        if path.hasPrefix("/Volumes/") {
            return .diskImage
        }
        if path.hasPrefix("/Applications/") {
            return .applications
        }
        if path.hasPrefix(home + "/Applications/") {
            return .userApplications
        }
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") {
            return .buildProducts
        }
        return .other
    }

    /// Whether Kadr should offer to move itself before anything attaches to this path.
    var shouldOfferMove: Bool {
        self == .diskImage || self == .translocated
    }
}

// MARK: - Redaction

nonisolated enum DiagnosticsRedaction {
    /// Shortens the home folder to `~` wherever it appears, so a path says where in the
    /// home folder something is without saying whose home folder it is.
    static func redactingHome(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    /// A preference value as short, redacted text. Data blobs (window frames, bookmarks,
    /// encoded shortcuts) are reported by size only: a bookmark embeds a full path, and
    /// the bytes themselves would tell a reader nothing.
    static func describe(_ value: Any, home: String = NSHomeDirectory()) -> String {
        let text: String = switch value {
        case let data as Data:
            "<\(data.count) bytes>"
        case let url as URL:
            url.isFileURL ? url.path : url.absoluteString
        case let array as [Any]:
            "[" + array.map { describe($0, home: home) }.joined(separator: ", ") + "]"
        case let dictionary as [String: Any]:
            "{" + dictionary.keys.sorted().map { "\($0): \(describe(dictionary[$0] ?? "", home: home))" }
                .joined(separator: ", ") + "}"
        default:
            String(describing: value)
        }
        return redactingHome(text, home: home)
    }

    /// Kadr's own preferences, with the system's bookkeeping left out.
    ///
    /// `persistentDomain` holds only what has been written, which for Kadr means what
    /// the user changed or what a migration recorded — the "non-default settings".
    static func settings(from domain: [String: Any], home: String = NSHomeDirectory()) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in domain where !isSystemBookkeeping(key) {
            result[key] = describe(value, home: home)
        }
        return result
    }

    private static func isSystemBookkeeping(_ key: String) -> Bool {
        key.hasPrefix("NSWindow Frame")
            || key.hasPrefix("NSSplitView Subview Frames")
            || key.hasPrefix("NSNavPanel")
            || key.hasPrefix("NSNavLastRootDirectory")
            || key.hasPrefix("NSStatusItem Preferred Position")
            || key.hasPrefix("com.apple.")
    }
}

// MARK: - Collecting

extension DiagnosticsSnapshot {
    /// Everything that has to be read on the main actor, and nothing slow: disk sizes
    /// are filled in afterwards, off the main thread, by `DiagnosticsExporter`.
    @MainActor
    static func collect(
        hotkeyConflicts: [String: String],
        loginItem: String,
        historyItemCount: Int
    ) -> DiagnosticsSnapshot {
        let identity = BuildIdentity.current
        let bundlePath = Bundle.main.bundlePath
        let permissions = AppPermissionTracker()
        var permissionLabels: [String: String] = [:]
        for permission in AppPermission.allCases {
            permissionLabels[permission.rawValue] = permissions.status(permission).label
        }
        let domain = Bundle.main.bundleIdentifier
            .flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]

        return DiagnosticsSnapshot(
            generatedAt: Date(),
            app: App(
                version: identity.version,
                build: identity.build,
                commit: identity.commit,
                bundlePath: DiagnosticsRedaction.redactingHome(bundlePath),
                runLocation: RunLocation.classify(bundlePath: bundlePath)
            ),
            system: System(
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                osBuild: sysctlString("kern.osversion") ?? "—",
                hardwareModel: sysctlString("hw.model") ?? "—",
                architecture: machineArchitecture,
                isTranslated: sysctlInt("sysctl.proc_translated") == 1,
                freeDiskBytes: nil
            ),
            displays: NSScreen.screens.map(Display.init(screen:)),
            permissions: permissionLabels,
            hotkeyConflicts: hotkeyConflicts,
            loginItem: loginItem,
            settings: DiagnosticsRedaction.settings(from: domain),
            storage: Storage(studioSessionCount: 0, studioSessionBytes: 0, historyItemCount: historyItemCount)
        )
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

extension DiagnosticsSnapshot.Display {
    @MainActor
    init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        id = number?.uint32Value ?? 0
        frame = [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height].map(Double.init)
        scale = Double(screen.backingScaleFactor)
        isPrimary = screen.frame.origin == .zero
        hasNotch = screen.safeAreaInsets.top > 0
    }
}
