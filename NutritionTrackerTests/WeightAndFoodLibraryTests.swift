import XCTest
import SwiftData
@testable import NutritionTracker

@MainActor
final class WeightAndFoodLibraryTests: XCTestCase {

    private let calendar = TestSupport.calendar()

    // MARK: Weight history

    func testWeighingInTwiceOnOneDayKeepsOnePoint() {
        let context = TestSupport.makeContext()
        context.recordWeight(70.0, on: TestSupport.date(2026, 10, 1, 7), calendar: calendar)
        context.recordWeight(69.6, on: TestSupport.date(2026, 10, 1, 21), calendar: calendar)
        context.recordWeight(69.2, on: TestSupport.date(2026, 10, 2, 7), calendar: calendar)
        try? context.save()

        let entries = context.fetchWeightEntries()
        XCTAssertEqual(entries.map(\.weightKg), [69.6, 69.2])
    }

    func testImpossibleWeightsAreNotRecorded() {
        let context = TestSupport.makeContext()
        XCTAssertNil(context.recordWeight(0))
        XCTAssertNil(context.recordWeight(.nan))
        XCTAssertTrue(context.fetchWeightEntries().isEmpty)
    }

    func testProfileWeightOnlyAddsAPointWhenItChanged() {
        let context = TestSupport.makeContext()
        let profile = UserProfile(dateOfBirth: TestSupport.date(1995, 5, 17), sex: .male,
                                  heightCm: 175, weightKg: 72, goal: .maintain, activity: .active)
        context.insert(profile)
        context.recordProfileWeight(profile, now: TestSupport.date(2026, 10, 1))
        context.recordProfileWeight(profile, now: TestSupport.date(2026, 10, 8))
        XCTAssertEqual(context.fetchWeightEntries().count, 1)

        profile.weightKg = 71
        context.recordProfileWeight(profile, now: TestSupport.date(2026, 10, 15))
        XCTAssertEqual(context.fetchWeightEntries().map(\.weightKg), [72, 71])
    }

    func testSeedingUsesTheProfileOnce() {
        let context = TestSupport.makeContext()
        context.insert(UserProfile(dateOfBirth: TestSupport.date(1995, 5, 17), sex: .female,
                                   heightCm: 160, weightKg: 60, goal: .maintain,
                                   activity: .light))
        context.seedWeightHistoryIfNeeded()
        context.seedWeightHistoryIfNeeded()
        XCTAssertEqual(context.fetchWeightEntries().count, 1)
    }

    func testBackupRoundTripsWeights() throws {
        let context = TestSupport.makeContext()
        context.insert(WeightEntry(date: TestSupport.date(2026, 10, 1), weightKg: 70.5))
        context.insert(WeightEntry(date: TestSupport.date(2026, 10, 8), weightKg: 70.1))
        try context.save()

        let file = BackupService(context: context).makeBackup()
        XCTAssertEqual(file.weightEntries?.count, 2)

        let restored = TestSupport.makeContext()
        try BackupService(context: restored).importBackup(file, strategy: .replace)
        XCTAssertEqual(restored.fetchWeightEntries().map(\.weightKg), [70.5, 70.1])
    }

    // MARK: Graph maths

    private func point(_ day: Int, _ kg: Double) -> WeightPoint {
        WeightPoint(id: UUID(), date: TestSupport.date(2026, 10, day), kg: kg)
    }

    func testRangeKeepsOnlyRecentPoints() {
        let now = TestSupport.date(2026, 10, 31)
        let points = [point(1, 72), point(20, 71), point(30, 70)]
        let month = WeightStats.filter(points, range: .month, now: now, calendar: calendar)
        XCTAssertEqual(month.count, 3)
        let all = WeightStats.filter(points, range: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.count, 3)
        let later = TestSupport.date(2027, 1, 31)
        XCTAssertEqual(WeightStats.filter(points, range: .month, now: later, calendar: calendar).count, 0)
    }

    func testSmoothingAveragesTheTrailingWeek() {
        let points = [point(1, 72), point(2, 71), point(3, 70)]
        let smoothed = WeightStats.smoothed(points)
        XCTAssertEqual(smoothed.map(\.kg), [72, 71.5, 71], accuracy: 0.001)
    }

    func testChangeIsLastMinusFirst() {
        XCTAssertEqual(WeightStats.change([point(1, 72), point(9, 70.5)]) ?? 0, -1.5, accuracy: 0.001)
        XCTAssertNil(WeightStats.change([point(1, 72)]))
    }

    func testAxisFitsDataAndGoalWithoutStartingAtZero() {
        let domain = WeightStats.yDomain([point(1, 72), point(2, 70)], goal: 65)
        XCTAssertLessThan(domain.lowerBound, 65)
        XCTAssertGreaterThan(domain.lowerBound, 50)
        XCTAssertGreaterThan(domain.upperBound, 72)
    }

    // MARK: Food library

    private func entry(_ name: String, day: Int, kcal: Double = 300) -> FoodEntry {
        TestSupport.entry(name: name, at: TestSupport.date(2026, 10, day), calories: kcal)
    }

    func testSameFoodIsMergedWhateverItsCaseOrSpacing() {
        let records = FoodLibrary.records(from: [
            entry("Nasi Lemak", day: 1), entry("nasi  lemak ", day: 5), entry("Teh Tarik", day: 3)
        ])
        XCTAssertEqual(records.count, 2)
        let nasi = records.first { $0.id == "nasi lemak" }
        XCTAssertEqual(nasi?.timesLogged, 2)
        XCTAssertEqual(nasi?.lastEaten, TestSupport.date(2026, 10, 5))
    }

    func testSearchMatchesEveryWordTyped() {
        let records = FoodLibrary.records(from: [
            entry("Nasi Lemak Ayam", day: 1), entry("Nasi Goreng", day: 2), entry("Roti Canai", day: 3)
        ])
        XCTAssertEqual(FoodLibrary.filter(records, query: "nasi").count, 2)
        XCTAssertEqual(FoodLibrary.filter(records, query: "lemak ayam").count, 1)
        XCTAssertEqual(FoodLibrary.filter(records, query: "NASI goreng").count, 1)
        XCTAssertEqual(FoodLibrary.filter(records, query: "  ").count, 3)
        XCTAssertTrue(FoodLibrary.filter(records, query: "pizza").isEmpty)
    }

    func testSortOrders() {
        let records = FoodLibrary.records(from: [
            entry("Banana", day: 1), entry("Banana", day: 2), entry("Apple", day: 9), entry("Cake", day: 5)
        ])
        XCTAssertEqual(FoodLibrary.sorted(records, by: .recent).map(\.name), ["Apple", "Cake", "Banana"])
        XCTAssertEqual(FoodLibrary.sorted(records, by: .mostLogged).first?.name, "Banana")
        XCTAssertEqual(FoodLibrary.sorted(records, by: .name).map(\.name), ["Apple", "Banana", "Cake"])
    }
}

private func XCTAssertEqual(_ values: [Double], _ expected: [Double], accuracy: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(values.count, expected.count, file: file, line: line)
    for (value, wanted) in zip(values, expected) {
        XCTAssertEqual(value, wanted, accuracy: accuracy, file: file, line: line)
    }
}
