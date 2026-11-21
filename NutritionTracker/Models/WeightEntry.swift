import Foundation
import SwiftData

/// One weigh-in. The profile only holds the latest weight, so this keeps the
/// history the weight graph is drawn from.
@Model
final class WeightEntry {
    var id: UUID
    var date: Date
    var weightKg: Double
    var createdAt: Date

    init(id: UUID = UUID(), date: Date = .now, weightKg: Double) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.createdAt = .now
    }
}

// MARK: - Store access

extension ModelContext {

    func fetchWeightEntries() -> [WeightEntry] {
        let descriptor = FetchDescriptor<WeightEntry>(sortBy: [SortDescriptor(\.date, order: .forward)])
        return (try? fetch(descriptor)) ?? []
    }

    /// Records a weigh-in. One per local day: weighing in again the same day
    /// replaces that day's figure instead of adding a second point.
    @discardableResult
    func recordWeight(_ kg: Double, on date: Date = .now,
                      calendar: Calendar = .autoupdatingCurrent) -> WeightEntry? {
        guard kg.isFinite, kg > 0 else { return nil }
        let day = LocalDay.interval(containing: date, calendar: calendar)
        let start = day.start
        let end = day.end
        var descriptor = FetchDescriptor<WeightEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end })
        descriptor.fetchLimit = 1
        if let existing = try? fetch(descriptor).first {
            existing.weightKg = kg
            existing.date = date
            return existing
        }
        let entry = WeightEntry(date: date, weightKg: kg)
        insert(entry)
        return entry
    }

    /// Keeps the history in step with the profile's weight, wherever it was
    /// changed (settings, the assistant, a check-in): adds a point only when
    /// the weight differs from the latest one on record.
    func recordProfileWeight(_ profile: UserProfile, now: Date = .now) {
        var descriptor = FetchDescriptor<WeightEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        if let latest = try? fetch(descriptor).first,
           abs(latest.weightKg - profile.weightKg) < 0.05 { return }
        recordWeight(profile.weightKg, on: now)
    }

    /// First launch with the weight graph: the profile's weight is the one
    /// point there is, dated to when it was last updated.
    func seedWeightHistoryIfNeeded() {
        guard let profile = loadUserProfile(), fetchWeightEntries().isEmpty else { return }
        recordWeight(profile.weightKg, on: min(profile.updatedAt, .now))
        try? save()
    }
}

// MARK: - Graph maths

struct WeightPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kg: Double
}

/// How far back the graph looks.
enum WeightRange: String, CaseIterable, Identifiable {
    case month, threeMonths, sixMonths, year, all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .month: "1M"
        case .threeMonths: "3M"
        case .sixMonths: "6M"
        case .year: "1Y"
        case .all: "All"
        }
    }

    var days: Int? {
        switch self {
        case .month: 30
        case .threeMonths: 90
        case .sixMonths: 180
        case .year: 365
        case .all: nil
        }
    }
}

enum WeightStats {

    static func points(_ entries: [WeightEntry]) -> [WeightPoint] {
        entries.map { WeightPoint(id: $0.id, date: $0.date, kg: $0.weightKg) }
            .sorted { $0.date < $1.date }
    }

    /// The points inside `range`, ending now.
    static func filter(_ points: [WeightPoint], range: WeightRange,
                       now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [WeightPoint] {
        guard let days = range.days,
              let start = calendar.date(byAdding: .day, value: -days, to: now) else { return points }
        return points.filter { $0.date >= start }
    }

    /// Trailing average over `windowDays`, which irons out the day-to-day
    /// swings of water weight so the direction of travel shows.
    static func smoothed(_ points: [WeightPoint], windowDays: Int = 7) -> [WeightPoint] {
        let window = TimeInterval(windowDays) * 86_400
        return points.map { point in
            let inWindow = points.filter { $0.date <= point.date && point.date.timeIntervalSince($0.date) < window }
            let mean = inWindow.reduce(0) { $0 + $1.kg } / Double(max(1, inWindow.count))
            return WeightPoint(id: point.id, date: point.date, kg: mean)
        }
    }

    /// Last minus first: negative means weight went down.
    static func change(_ points: [WeightPoint]) -> Double? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        return last.kg - first.kg
    }

    /// A y-axis that fits the data (and the goal) with a little room, instead
    /// of starting at zero, which would flatten any real change into a line.
    static func yDomain(_ points: [WeightPoint], goal: Double?) -> ClosedRange<Double> {
        let values = points.map(\.kg) + (goal.map { [$0] } ?? [])
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        let padding = max(1, (high - low) * 0.15)
        return (low - padding)...(high + padding)
    }
}
