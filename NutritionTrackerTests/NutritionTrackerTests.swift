import XCTest
import SwiftData
@testable import NutritionTracker

final class NutritionTrackerTests: XCTestCase {
    func testTargetCalculationAndNoExerciseDoubleCount() {
        let dob = Calendar(identifier: .gregorian).date(from: DateComponents(year: 1996, month: 1, day: 1))!
        let a = UserProfile(dateOfBirth: dob, sex: .male, heightCm: 180, weightKg: 80,
                            goal: .maintain, activity: .moderate, strengthSessions: 0)
        let b = UserProfile(dateOfBirth: dob, sex: .male, heightCm: 180, weightKg: 80,
                            goal: .maintain, activity: .moderate, strengthSessions: 6)
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let first = NutritionTargetCalculator.calculate(profile: a, now: date)
        XCTAssertEqual(first, NutritionTargetCalculator.calculate(profile: b, now: date))
        XCTAssertEqual(first.protein, 128)
        XCTAssertGreaterThan(first.carbs, 0)
    }
    func testSimpleAndCompositeScaling() {
        let n = Nutrition(calories: 100, protein: 10)
        let simple = FoodEntry(name: "shake", quantity: 2, nutrition: n)
        XCTAssertEqual(simple.total.calories, 200)
        let rice = IngredientItem(name: "rice", quantity: 150, servingSize: 100, unit: .gram,
                                  nutrition: Nutrition(calories: 130))
        let egg = IngredientItem(name: "egg", nutrition: Nutrition(calories: 70))
        let meal = FoodEntry(name: "rice and egg", quantity: 2, ingredients: [rice, egg])
        XCTAssertEqual(meal.total.calories, 530)
        rice.quantity = 0
        XCTAssertEqual(meal.total.calories, 140)
    }
    func testLocalDayMidnightAndTimezone() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var malaysia = utc; malaysia.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = ISO8601DateFormatter().date(from: "2026-09-25T23:30:00Z")!
        let later = ISO8601DateFormatter().date(from: "2026-09-26T00:30:00Z")!
        let entry = FoodEntry(name: "test", consumedAt: date)
        XCTAssertTrue(LocalDay.contains(entry, date: later, calendar: malaysia))
        XCTAssertFalse(LocalDay.contains(entry, date: later, calendar: utc))
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-09-25T23:59:00Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-09-26T00:01:00Z")!
        XCTAssertFalse(LocalDay.interval(containing: beforeMidnight, calendar: utc).contains(afterMidnight))
    }
    func testOpenFoodFactsMissingFieldsAndStrings() throws {
        let data = Data(#"{"status":1,"product":{"product_name":"Yoghurt","nutriments":{"energy-kcal_100g":"80","proteins_100g":5}}}"#.utf8)
        let decoded = try JSONDecoder().decode(OFFResponse.self, from: data)
        XCTAssertEqual(decoded.product?.nutriments?.energyKcal100g, 80)
        XCTAssertNil(decoded.product?.nutriments?.fat100g)
    }
    func testBackupRoundTripAndValidation() throws {
        let entry = FoodEntry(name: "Test", nutrition: Nutrition(calories: 100),
                              ingredients: [IngredientItem(name: "A", nutrition: Nutrition(calories: 50))])
        let backup = NutritionBackup(profile: nil, target: nil, foodEntries: [FoodBackup(entry)], barcodeCache: [])
        let decoded = try BackupService.decode(BackupService.encode(backup))
        XCTAssertEqual(decoded.foodEntries, backup.foodEntries)
        var bad = decoded; bad.schemaVersion = 99
        XCTAssertThrowsError(try BackupService.decode(BackupService.encode(bad)))
    }
    func testAIResultReviewDraftAndConfidence() {
        let result = AnalysisResult(detections: [Detection(name: "rice", canonicalID: "rice", confidence: 0.43)],
                                    portions: [PortionPrediction(canonicalID: "rice", name: "rice", grams: 150,
                                                                  nutrition: Nutrition(calories: 195))])
        let draft = PhotoAnalyzer.draft(from: result)
        XCTAssertEqual(draft.source, .photoAI)
        XCTAssertEqual(draft.ingredients.first?.confidence, 0.43)
        XCTAssertEqual(draft.total.calories, 195, accuracy: 0.001)
    }
    func testCanonicalNutritionLookup() {
        let row = ReferenceFood(canonicalID: "rice_white", name: "White rice", source: "MyFCD",
                                per100g: Nutrition(calories: 130, protein: 2.5))
        let repository = BundledNutritionRepository(foods: [row])
        XCTAssertEqual(repository.food(for: "rice_white")?.per100g.calories, 130)
        XCTAssertNil(repository.food(for: "rice_unknown"))
    }
}
