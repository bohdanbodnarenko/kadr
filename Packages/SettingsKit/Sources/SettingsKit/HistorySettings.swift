import Foundation

/// How long history keeps captures (docs/03 §5).
public enum HistoryRetention: String, CaseIterable, SettingValue {
    case forever
    case thirtyDays
    case sevenDays
    case session

    public var title: String {
        switch self {
        case .forever: String(localized: "Forever", bundle: .module)
        case .thirtyDays: String(localized: "30 days", bundle: .module)
        case .sevenDays: String(localized: "7 days", bundle: .module)
        case .session: String(localized: "This session only", bundle: .module)
        }
    }

    /// `nil` means keep forever (until the size cap). Session-only is a launch cutoff,
    /// not an age, so it is also `nil` here.
    public var maxAge: TimeInterval? {
        switch self {
        case .forever, .session: nil
        case .thirtyDays: 30 * 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        }
    }
}

/// Hard ceiling on the library, enforced with LRU eviction (docs/03 §5).
public enum HistorySizeCap: String, CaseIterable, SettingValue {
    case unlimited
    case megabytes512
    case gigabytes1
    case gigabytes5
    case gigabytes10

    public var title: String {
        switch self {
        case .unlimited: String(localized: "No limit", bundle: .module)
        case .megabytes512: String(localized: "512 MB", bundle: .module)
        case .gigabytes1: String(localized: "1 GB", bundle: .module)
        case .gigabytes5: String(localized: "5 GB", bundle: .module)
        case .gigabytes10: String(localized: "10 GB", bundle: .module)
        }
    }

    /// `nil` means no cap.
    public var bytes: Int64? {
        switch self {
        case .unlimited: nil
        case .megabytes512: 512 * 1024 * 1024
        case .gigabytes1: 1024 * 1024 * 1024
        case .gigabytes5: 5 * 1024 * 1024 * 1024
        case .gigabytes10: 10 * 1024 * 1024 * 1024
        }
    }
}
