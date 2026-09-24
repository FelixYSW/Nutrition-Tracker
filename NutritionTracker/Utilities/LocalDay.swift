import Foundation

enum LocalDay {
    static func interval(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86400)
    }
    static func contains(_ entry: FoodEntry, date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let day = interval(containing: date, calendar: calendar)
        return entry.consumedAt >= day.start && entry.consumedAt < day.end
    }
    static func entries(_ all: [FoodEntry], on date: Date, calendar: Calendar = .autoupdatingCurrent) -> [FoodEntry] {
        all.filter { contains($0, date: date, calendar: calendar) }.sorted { $0.consumedAt > $1.consumedAt }
    }
    static func total(_ entries: [FoodEntry]) -> Nutrition { entries.reduce(.zero) { $0 + $1.total } }
}
