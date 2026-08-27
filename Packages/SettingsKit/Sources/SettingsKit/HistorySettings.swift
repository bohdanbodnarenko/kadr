import Foundation

/// How long history keeps captures (docs/03 §5).
public enum HistoryRetention: String, CaseIterable, SettingValue {
    case forever
    case thirtyDays
    case sevenDays
    case session

    public var title: String {
        switch self {
        case .forever: "Forever"
        case .thirtyDays: "30 days"
        case .sevenDays: "7 days"
        case .session: "This session only"
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
        case .unlimited: "No limit"
        case .megabytes512: "512 MB"
        case .gigabytes1: "1 GB"
        case .gigabytes5: "5 GB"
        case .gigabytes10: "10 GB"
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
