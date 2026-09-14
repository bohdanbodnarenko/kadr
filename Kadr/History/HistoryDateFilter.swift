import Foundation

/// Date presets for the history browser (docs/03 §5).
enum HistoryDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case lastSevenDays
    case lastThirtyDays

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "Any time"
        case .today: "Today"
        case .lastSevenDays: "Last 7 days"
        case .lastThirtyDays: "Last 30 days"
        }
    }

    var capturedAfter: Date? {
        let calendar = Calendar.current
        switch self {
        case .all: return nil
        case .today: return calendar.startOfDay(for: Date())
        case .lastSevenDays: return calendar.date(byAdding: .day, value: -7, to: Date())
        case .lastThirtyDays: return calendar.date(byAdding: .day, value: -30, to: Date())
        }
    }
}
