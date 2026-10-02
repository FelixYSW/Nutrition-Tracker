import Foundation

/// Time scales offered by the Trends view (spec section 15).
enum TrendScale: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly, monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    /// How many buckets to show by default.
    var bucketCount: Int {
        switch self {
        case .daily: 14
        case .weekly: 8
        case .monthly: 6
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
    }

    /// Weekly and monthly buckets are plotted as daily averages, so they stay
    /// directly comparable to a daily target band. Plotting weekly *totals*
    /// against a daily target would be meaningless.
    var plotsDailyAverage: Bool { self != .daily }
}

/// One aggregated point on a trend chart.
struct TrendBucket: Identifiable, Equatable, Sendable {
    let id: Date
    let interval: DateInterval
    let label: String
    /// Sum of everything logged in this bucket.
    let total: Nutrition
    /// Number of calendar days in the bucket that have already elapsed. A
    /// partially elapsed current week/month counts only the days so far, so the
    /// average is not dragged down by days that have not happened yet.
    let elapsedDays: Int
    /// How many of those days actually have at least one entry.
    let daysWithEntries: Int
    let entryCount: Int

    /// Average per elapsed day. This is what weekly/monthly charts plot.
    var dailyAverage: Nutrition {
        guard elapsedDays > 0 else { return .zero }
        return total * (1.0 / Double(elapsedDays))
    }

    /// The value a chart should plot for a given scale.
    func plotValue(for scale: TrendScale) -> Nutrition {
        scale.plotsDailyAverage ? dailyAverage : total
    }

    /// No entries at all: the UI shows a "no data" state rather than a
    /// misleading zero point on the line (spec section 15).
    var hasData: Bool { daysWithEntries > 0 }

    /// Some days logged but not all - worth flagging, because an average over a
    /// week where only two days were tracked is not a real weekly average.
    var isSparse: Bool {
        guard elapsedDays > 0, daysWithEntries > 0 else { return false }
        return Double(daysWithEntries) / Double(elapsedDays) < 0.5
    }

    var coverage: Double {
        guard elapsedDays > 0 else { return 0 }
        return Double(daysWithEntries) / Double(elapsedDays)
    }
}

/// Builds trend buckets on the fly from `FoodEntry` records.
///
/// Nothing is persisted: this reduces the same `consumedAt` field the Dashboard
/// filters on, so there is no rollover or sync logic to maintain and no stored
/// aggregate that can drift out of date (spec sections 14 and 15).
enum TrendAggregator {

    static func buckets(entries: [FoodEntry],
                        scale: TrendScale,
                        endingOn referenceDate: Date = .now,
                        count: Int? = nil,
                        calendar: Calendar = .autoupdatingCurrent) -> [TrendBucket] {

        let bucketCount = max(1, count ?? scale.bucketCount)
        let intervals = self.intervals(scale: scale,
                                       endingOn: referenceDate,
                                       count: bucketCount,
                                       calendar: calendar)

        // Bucket the entries once by start date instead of rescanning the whole
        // array per bucket, so this stays linear in the number of entries.
        var byBucketStart: [Date: [FoodEntry]] = [:]
        let earliest = intervals.first?.start ?? referenceDate
        let latest = intervals.last?.end ?? referenceDate

        for entry in entries {
            let consumed = entry.consumedAt
            guard consumed >= earliest, consumed < latest else { continue }
            guard let match = intervals.first(where: { $0.contains(consumed) }) else { continue }
            byBucketStart[match.start, default: []].append(entry)
        }

        return intervals.map { interval in
            let bucketEntries = byBucketStart[interval.start] ?? []
            let total = bucketEntries.reduce(Nutrition.zero) { $0 + $1.total }

            let distinctDays = Set(bucketEntries.map {
                LocalDay.start(of: $0.consumedAt, calendar: calendar)
            })

            return TrendBucket(id: interval.start,
                               interval: interval,
                               label: label(for: interval, scale: scale, calendar: calendar),
                               total: total,
                               elapsedDays: elapsedDays(in: interval,
                                                        asOf: referenceDate,
                                                        calendar: calendar),
                               daysWithEntries: distinctDays.count,
                               entryCount: bucketEntries.count)
        }
    }

    /// Oldest-first list of consecutive intervals ending with the one that
    /// contains `referenceDate`.
    static func intervals(scale: TrendScale,
                          endingOn referenceDate: Date,
                          count: Int,
                          calendar: Calendar = .autoupdatingCurrent) -> [DateInterval] {

        guard let current = calendar.dateInterval(of: scale.calendarComponent,
                                                  for: referenceDate) else {
            return [LocalDay.interval(containing: referenceDate, calendar: calendar)]
        }

        var result: [DateInterval] = []
        var cursor = current

        for _ in 0..<count {
            result.append(cursor)
            guard let previousDate = calendar.date(byAdding: scale.calendarComponent,
                                                   value: -1, to: cursor.start),
                  let previous = calendar.dateInterval(of: scale.calendarComponent,
                                                       for: previousDate) else {
                break
            }
            cursor = previous
        }

        return result.reversed()
    }

    /// Days in the interval that have already happened, capped at the reference
    /// date so the in-progress bucket is not penalised for future days.
    static func elapsedDays(in interval: DateInterval,
                            asOf referenceDate: Date,
                            calendar: Calendar = .autoupdatingCurrent) -> Int {
        guard referenceDate >= interval.start else { return 0 }

        func days(from start: Date, to end: Date) -> Int {
            calendar.dateComponents([.day],
                                    from: LocalDay.start(of: start, calendar: calendar),
                                    to: LocalDay.start(of: end, calendar: calendar)).day ?? 0
        }

        // A fully elapsed interval counts all of its days. `interval.end` is the
        // *next* period's first midnight, so the day count is end - start, with
        // no +1 (a single past day is 1, not 2).
        if referenceDate >= interval.end {
            return max(1, days(from: interval.start, to: interval.end))
        }

        // The in-progress interval counts its days so far, including today.
        return days(from: interval.start, to: referenceDate) + 1
    }

    static func label(for interval: DateInterval,
                      scale: TrendScale,
                      calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch scale {
        case .daily:
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
        case .weekly:
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
            return formatter.string(from: interval.start)
        case .monthly:
            formatter.setLocalizedDateFormatFromTemplate("MMMyy")
        }
        return formatter.string(from: interval.start)
    }

    // MARK: - Natural-language summary (feeds the assistant, spec section 29A.3)

    /// Counts how many buckets with data fell under / within / over the band for
    /// a nutrient. The assistant turns this into a sentence such as
    /// "you were under your protein minimum 4 of the last 7 logged days".
    struct StateTally: Equatable, Sendable {
        var under = 0
        var within = 0
        var over = 0
        var noData = 0

        var withData: Int { under + within + over }
    }

    static func tally(buckets: [TrendBucket],
                      nutrient: Nutrient,
                      range: NutrientRange,
                      scale: TrendScale) -> StateTally {
        var tally = StateTally()
        for bucket in buckets {
            guard bucket.hasData else {
                tally.noData += 1
                continue
            }
            let value = bucket.plotValue(for: scale)[nutrient]
            switch range.state(consumed: value) {
            case .under: tally.under += 1
            case .within: tally.within += 1
            case .over: tally.over += 1
            }
        }
        return tally
    }
}
