import XCTest
@testable import NutritionTracker

/// Daily/weekly/monthly aggregation, including sparse data (spec section 35).
final class TrendAggregatorTests: XCTestCase {

    private let kl = TestSupport.calendar("Asia/Kuala_Lumpur")
    /// Friday 2026-10-02, midday.
    private var now: Date { TestSupport.date(2026, 10, 2, 12, calendar: kl) }

    func testDailyProducesRequestedBucketsOldestFirst() {
        let buckets = TrendAggregator.buckets(entries: [], scale: .daily,
                                              endingOn: now, count: 14, calendar: kl)
        XCTAssertEqual(buckets.count, 14)
        XCTAssertEqual(buckets.last?.interval.start, TestSupport.date(2026, 10, 2, 0, calendar: kl))
        XCTAssertEqual(buckets.first?.interval.start, TestSupport.date(2026, 9, 19, 0, calendar: kl))
        XCTAssertTrue(zip(buckets, buckets.dropFirst()).allSatisfy { $0.interval.end == $1.interval.start })
    }

    func testEmptyBucketsHaveNoDataRatherThanZero() {
        let buckets = TrendAggregator.buckets(entries: [], scale: .daily,
                                              endingOn: now, count: 7, calendar: kl)
        XCTAssertTrue(buckets.allSatisfy { !$0.hasData })
    }

    func testDailyTotalsAssignedToCorrectDay() {
        let entries = [
            TestSupport.entry(at: TestSupport.date(2026, 10, 1, 8, calendar: kl), calories: 500),
            TestSupport.entry(at: TestSupport.date(2026, 10, 1, 20, calendar: kl), calories: 700),
            TestSupport.entry(at: TestSupport.date(2026, 10, 2, 9, calendar: kl), calories: 300)
        ]
        let buckets = TrendAggregator.buckets(entries: entries, scale: .daily,
                                              endingOn: now, count: 3, calendar: kl)
        XCTAssertEqual(buckets.map(\.total.calories), [0, 1200, 300])
        XCTAssertEqual(buckets[1].entryCount, 2)
        XCTAssertEqual(buckets[1].daysWithEntries, 1)
    }

    /// Regression: a fully elapsed single day must count as one day, not two.
    func testPastDailyBucketCountsOneElapsedDay() {
        let buckets = TrendAggregator.buckets(entries: [], scale: .daily,
                                              endingOn: now, count: 3, calendar: kl)
        XCTAssertEqual(buckets.map(\.elapsedDays), [1, 1, 1])
    }

    func testDailyPlotsTotalNotAverage() {
        let entries = [TestSupport.entry(at: TestSupport.date(2026, 10, 1, 8, calendar: kl), calories: 900)]
        let bucket = TrendAggregator.buckets(entries: entries, scale: .daily,
                                             endingOn: now, count: 2, calendar: kl)[0]
        XCTAssertEqual(bucket.plotValue(for: .daily).calories, 900)
        XCTAssertEqual(bucket.dailyAverage.calories, 900, "one elapsed day")
    }

    func testCompletedWeekAveragesOverSevenDays() {
        // Week of Mon 2026-09-21 .. Sun 2026-09-27, fully elapsed.
        let entries = (21...27).map {
            TestSupport.entry(at: TestSupport.date(2026, 9, $0, 12, calendar: kl), calories: 2000)
        }
        let buckets = TrendAggregator.buckets(entries: entries, scale: .weekly,
                                              endingOn: now, count: 3, calendar: kl)
        let week = buckets.first { $0.interval.start == TestSupport.date(2026, 9, 21, 0, calendar: kl) }!
        XCTAssertEqual(week.elapsedDays, 7)
        XCTAssertEqual(week.total.calories, 14000)
        XCTAssertEqual(week.plotValue(for: .weekly).calories, 2000, accuracy: 0.001)
        XCTAssertFalse(week.isSparse)
    }

    func testCurrentWeekCountsOnlyDaysSoFar() {
        // Current week started Mon 2026-09-28; "now" is Fri 10-02 => 5 days.
        let buckets = TrendAggregator.buckets(entries: [], scale: .weekly,
                                              endingOn: now, count: 1, calendar: kl)
        XCTAssertEqual(buckets[0].elapsedDays, 5)
    }

    func testSparseWeekIsFlagged() {
        let entries = [TestSupport.entry(at: TestSupport.date(2026, 9, 22, 12, calendar: kl), calories: 2000)]
        let buckets = TrendAggregator.buckets(entries: entries, scale: .weekly,
                                              endingOn: now, count: 3, calendar: kl)
        let week = buckets.first { $0.interval.start == TestSupport.date(2026, 9, 21, 0, calendar: kl) }!
        XCTAssertTrue(week.hasData)
        XCTAssertTrue(week.isSparse, "1 of 7 days logged")
        XCTAssertEqual(week.coverage, 1.0 / 7.0, accuracy: 0.0001)
    }

    func testMonthlyBuckets() {
        let entries = [
            TestSupport.entry(at: TestSupport.date(2026, 9, 10, calendar: kl), calories: 1500),
            TestSupport.entry(at: TestSupport.date(2026, 8, 31, 23, 59, calendar: kl), calories: 800)
        ]
        let buckets = TrendAggregator.buckets(entries: entries, scale: .monthly,
                                              endingOn: now, count: 3, calendar: kl)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets.map(\.total.calories), [800, 1500, 0])
        XCTAssertEqual(buckets[1].elapsedDays, 30, "September is fully elapsed")
        XCTAssertEqual(buckets[2].elapsedDays, 2, "October 1-2 so far")
    }

    func testEntriesOutsideWindowIgnored() {
        let old = TestSupport.entry(at: TestSupport.date(2025, 1, 1, calendar: kl), calories: 5000)
        let buckets = TrendAggregator.buckets(entries: [old], scale: .daily,
                                              endingOn: now, count: 7, calendar: kl)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.total.calories }, 0)
    }

    func testTallyUsesSameRangeLogicAsDashboard() {
        let range = NutrientRange(min: 1800, max: 2200)
        let entries = [
            TestSupport.entry(at: TestSupport.date(2026, 9, 29, calendar: kl), calories: 1500), // under
            TestSupport.entry(at: TestSupport.date(2026, 9, 30, calendar: kl), calories: 1800), // within (boundary)
            TestSupport.entry(at: TestSupport.date(2026, 10, 1, calendar: kl), calories: 2600)  // over
        ]
        let buckets = TrendAggregator.buckets(entries: entries, scale: .daily,
                                              endingOn: now, count: 5, calendar: kl)
        let tally = TrendAggregator.tally(buckets: buckets, nutrient: .calories,
                                          range: range, scale: .daily)
        XCTAssertEqual(tally.under, 1)
        XCTAssertEqual(tally.within, 1)
        XCTAssertEqual(tally.over, 1)
        XCTAssertEqual(tally.noData, 2, "empty days are not counted as under")
    }
}
