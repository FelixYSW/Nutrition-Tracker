import Foundation

/// Date-range helpers for "the current local calendar day".
///
/// The Dashboard computes today's totals by filtering `FoodEntry.consumedAt`
/// into this interval. There is no stored daily aggregate and no zero-filled
/// row per day, so midnight needs no migration step - the query simply starts
/// matching a new interval (spec section 14).
enum LocalDay {

    /// Default calendar is `autoupdatingCurrent` so a timezone change is picked
    /// up without the app being relaunched.
    static func calendar() -> Calendar { .autoupdatingCurrent }

    static func interval(containing date: Date,
                         calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        if let interval = calendar.dateInterval(of: .day, for: date) {
            return interval
        }
        // Fallback for a calendar that cannot produce a day interval. Note this
        // assumes a 24h day, which is why it is only a fallback: DST days are
        // 23 or 25 hours and `dateInterval(of:)` handles them correctly.
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, duration: 24 * 60 * 60)
    }

    static func start(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        interval(containing: date, calendar: calendar).start
    }

    static func contains(_ entry: FoodEntry, date: Date,
                         calendar: Calendar = .autoupdatingCurrent) -> Bool {
        contains(entry.consumedAt, date: date, calendar: calendar)
    }

    /// Half-open comparison: `[start, end)`. An entry logged exactly at midnight
    /// belongs to the new day, never to both days.
    static func contains(_ instant: Date, date: Date,
                         calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let day = interval(containing: date, calendar: calendar)
        return instant >= day.start && instant < day.end
    }

    static func entries(_ all: [FoodEntry], on date: Date,
                        calendar: Calendar = .autoupdatingCurrent) -> [FoodEntry] {
        all.filter { contains($0, date: date, calendar: calendar) }
            .sorted { $0.consumedAt > $1.consumedAt }
    }

    static func total(_ entries: [FoodEntry]) -> Nutrition {
        entries.reduce(.zero) { $0 + $1.total }
    }

    static func isToday(_ date: Date, now: Date = .now,
                        calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }
}

enum AppFormatters {

    static func quantity(_ value: Double, unit: ServingUnit) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = unit.fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Nutrition figures are estimates, so they are shown as whole numbers -
    /// decimal places would imply precision the pipeline cannot deliver.
    static func amount(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(Int(value.rounded()))
    }

    static func range(_ range: NutrientRange) -> String {
        "\(amount(range.min))-\(amount(range.max))"
    }

    static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
