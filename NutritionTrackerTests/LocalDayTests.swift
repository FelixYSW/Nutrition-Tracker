import XCTest
import SwiftData
@testable import NutritionTracker

/// Midnight, date-boundary and timezone behaviour (spec sections 14, 35).
final class LocalDayTests: XCTestCase {

    private let kl = TestSupport.calendar("Asia/Kuala_Lumpur")

    func testIntervalCoversWholeLocalDay() {
        let interval = LocalDay.interval(containing: TestSupport.date(2026, 10, 2, 15, calendar: kl),
                                         calendar: kl)
        XCTAssertEqual(interval.start, TestSupport.date(2026, 10, 2, 0, calendar: kl))
        XCTAssertEqual(interval.end, TestSupport.date(2026, 10, 3, 0, calendar: kl))
    }

    func testIntervalIsHalfOpenAtMidnight() {
        let day = TestSupport.date(2026, 10, 2, calendar: kl)
        let lastSecond = TestSupport.date(2026, 10, 2, 23, 59, 59, calendar: kl)
        let midnight = TestSupport.date(2026, 10, 3, 0, 0, 0, calendar: kl)

        XCTAssertTrue(LocalDay.contains(lastSecond, date: day, calendar: kl))
        XCTAssertFalse(LocalDay.contains(midnight, date: day, calendar: kl),
                       "an entry at exactly 00:00 belongs only to the new day")
        XCTAssertTrue(LocalDay.contains(midnight, date: midnight, calendar: kl))
    }

    /// Flow F: at 23:59 today's foods are visible; at 00:00 the day is empty but
    /// yesterday's entries still exist for the Calendar.
    func testMidnightRolloverResetsTotalsWithoutDeletingHistory() {
        let late = TestSupport.entry(name: "Supper", at: TestSupport.date(2026, 10, 2, 23, 59, calendar: kl),
                                     calories: 400)
        let lunch = TestSupport.entry(name: "Lunch", at: TestSupport.date(2026, 10, 2, 13, calendar: kl),
                                      calories: 600)
        let all = [late, lunch]

        let before = TestSupport.date(2026, 10, 2, 23, 59, calendar: kl)
        XCTAssertEqual(LocalDay.total(LocalDay.entries(all, on: before, calendar: kl)).calories, 1000)

        let after = TestSupport.date(2026, 10, 3, 0, 0, calendar: kl)
        let today = LocalDay.entries(all, on: after, calendar: kl)
        XCTAssertTrue(today.isEmpty)
        XCTAssertEqual(LocalDay.total(today), .zero)

        // History survives: the array was only filtered, never mutated.
        XCTAssertEqual(LocalDay.entries(all, on: before, calendar: kl).count, 2)
    }

    func testEntriesSortedNewestFirst() {
        let morning = TestSupport.entry(name: "A", at: TestSupport.date(2026, 10, 2, 8, calendar: kl))
        let evening = TestSupport.entry(name: "B", at: TestSupport.date(2026, 10, 2, 19, calendar: kl))
        let result = LocalDay.entries([morning, evening], on: morning, calendar: kl)
        XCTAssertEqual(result.map(\.name), ["B", "A"])
    }

    /// The same instant falls on different local days in different zones, which
    /// is why `autoupdatingCurrent` matters after travel.
    func testTimezoneChangeMovesDayBoundary() {
        let london = TestSupport.calendar("Europe/London")
        // 2026-10-02 23:30 in London is 2026-10-03 06:30 in Kuala Lumpur.
        let instant = TestSupport.date(2026, 10, 2, 23, 30, calendar: london)

        XCTAssertTrue(LocalDay.contains(instant, date: TestSupport.date(2026, 10, 2, calendar: london),
                                        calendar: london))
        XCTAssertTrue(LocalDay.contains(instant, date: TestSupport.date(2026, 10, 3, calendar: kl),
                                        calendar: kl))
        XCTAssertFalse(LocalDay.contains(instant, date: TestSupport.date(2026, 10, 2, calendar: kl),
                                         calendar: kl))
    }

    func testDaylightSavingDayIsNot24Hours() {
        let newYork = TestSupport.calendar("America/New_York")
        // US DST began 2026-03-08: that local day is 23 hours long.
        let interval = LocalDay.interval(containing: TestSupport.date(2026, 3, 8, 12, calendar: newYork),
                                         calendar: newYork)
        XCTAssertEqual(interval.duration, 23 * 60 * 60, accuracy: 1)
    }

    @MainActor
    func testStoreFetchFiltersByLocalDay() {
        let context = TestSupport.makeContext()
        context.insert(TestSupport.entry(name: "Yesterday", at: TestSupport.date(2026, 10, 1, 23, 59, calendar: kl)))
        context.insert(TestSupport.entry(name: "Today", at: TestSupport.date(2026, 10, 2, 0, 0, calendar: kl)))
        context.insert(TestSupport.entry(name: "Tomorrow", at: TestSupport.date(2026, 10, 3, 0, 0, calendar: kl)))
        try? context.save()

        let today = context.fetchEntries(on: TestSupport.date(2026, 10, 2, calendar: kl), calendar: kl)
        XCTAssertEqual(today.map(\.name), ["Today"])
    }

    @MainActor
    func testDayObserverPublishesOnlyOnRealChange() {
        let center = NotificationCenter()
        let start = Date.now
        let observer = DayChangeObserver(notificationCenter: center, now: start)
        let initial = observer.currentDayStart

        observer.refresh(now: start)
        XCTAssertEqual(observer.currentDayStart, initial, "same day: no change")

        let tomorrow = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: start)!
        observer.refresh(now: tomorrow)
        XCTAssertEqual(observer.currentDayStart, LocalDay.start(of: tomorrow))
        XCTAssertNotEqual(observer.currentDayStart, initial)
    }

    @MainActor
    func testDayObserverRespondsToDayChangedNotification() async {
        let center = NotificationCenter()
        let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: .now)!
        let observer = DayChangeObserver(notificationCenter: center, now: yesterday)
        XCTAssertNotEqual(observer.currentDayStart, LocalDay.start(of: .now))

        center.post(name: .NSCalendarDayChanged, object: nil)
        // The observer hops to the main actor via a Task; give it a turn.
        for _ in 0..<20 where observer.currentDayStart != LocalDay.start(of: .now) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(observer.currentDayStart, LocalDay.start(of: .now))
    }

    @MainActor
    func testDayObserverRespondsToTimezoneNotification() async {
        let center = NotificationCenter()
        let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: .now)!
        let observer = DayChangeObserver(notificationCenter: center, now: yesterday)

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        for _ in 0..<20 where observer.currentDayStart != LocalDay.start(of: .now) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(observer.currentDayStart, LocalDay.start(of: .now))
    }
}
