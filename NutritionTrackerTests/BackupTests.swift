import XCTest
import SwiftData
@testable import NutritionTracker

@MainActor
final class BackupTests: XCTestCase {

    private func seed(_ context: ModelContext) {
        let profile = UserProfile(dateOfBirth: TestSupport.date(1995, 5, 17), sex: .male,
                                  heightCm: 175, weightKg: 72, targetWeightKg: 68,
                                  goal: .recomposition, activity: .active,
                                  strengthSessionsPerWeek: 4, cardioSessionsPerWeek: 2,
                                  bodyFatPercent: 18)
        context.insert(profile)

        var ranges = TestSupport.ranges()
        ranges.protein = ranges.protein.withManualMax(170)
        context.insert(NutritionTarget(ranges: ranges))

        let composite = FoodEntry(
            name: "Nasi Lemak", consumedAt: TestSupport.date(2026, 10, 1, 8),
            quantity: 1, servingSize: 1, unit: .serving,
            ingredients: [
                IngredientItem(name: "Coconut rice", quantity: 200, servingSize: 100, unit: .gram,
                               nutritionPerServing: Nutrition(calories: 180, protein: 3, carbs: 28, fat: 6),
                               confidence: 0.91, canonicalID: "my.rice.coconut"),
                IngredientItem(name: "Sambal", quantity: 2, servingSize: 1, unit: .tablespoon,
                               nutritionPerServing: Nutrition(calories: 40, fat: 3))
            ],
            source: .photoAI)
        context.insert(composite)

        context.insert(FoodEntry(name: "Protein Shake", consumedAt: TestSupport.date(2026, 10, 1, 17),
                                 quantity: 1.5, servingSize: 1, unit: .scoop,
                                 nutritionPerServing: Nutrition(calories: 120, protein: 24)))

        context.insert(BarcodeProductCache(barcode: "9551", name: "Teh Botol",
                                           servingSize: 250, unit: .millilitre,
                                           nutritionPerServing: Nutrition(calories: 90, carbs: 22),
                                           isUserEntered: true))
        try? context.save()
    }

    /// DB objects -> export DTO -> JSON -> import DTO -> equivalent data.
    func testRoundTripPreservesEverything() throws {
        let source = TestSupport.makeContext()
        seed(source)
        let data = try BackupService(context: source).exportData()

        let validated = try BackupService.validate(data: data)
        XCTAssertEqual(validated.schemaVersion, BackupFile.currentSchemaVersion)

        let destination = TestSupport.makeContext()
        let summary = try BackupService(context: destination).importBackup(validated, strategy: .replace)
        XCTAssertEqual(summary.entriesImported, 2)
        XCTAssertEqual(summary.productsImported, 1)

        let originalEntries = try source.fetch(FetchDescriptor<FoodEntry>()).sorted { $0.name < $1.name }
        let restoredEntries = try destination.fetch(FetchDescriptor<FoodEntry>()).sorted { $0.name < $1.name }
        XCTAssertEqual(restoredEntries.map(\.id), originalEntries.map(\.id))
        for (original, restored) in zip(originalEntries, restoredEntries) {
            XCTAssertEqual(restored.total, original.total, original.name)
            XCTAssertEqual(restored.source, original.source)
            XCTAssertEqual(restored.consumedAt.timeIntervalSince1970,
                           original.consumedAt.timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(Set(restored.ingredients.map(\.id)), Set(original.ingredients.map(\.id)))
        }

        let restoredTarget = try XCTUnwrap(destination.loadNutritionTarget())
        XCTAssertEqual(restoredTarget.protein.max, 170)
        XCTAssertTrue(restoredTarget.protein.maxManuallyModified, "manual flags survive")

        let restoredProfile = try XCTUnwrap(destination.loadUserProfile())
        XCTAssertEqual(restoredProfile.goal, .recomposition)
        XCTAssertEqual(restoredProfile.bodyFatPercent, 18)

        XCTAssertEqual(destination.fetchCachedProduct(barcode: "9551")?.isUserEntered, true)

        // And a second export of the restored store matches the first.
        let reexported = try BackupService.validate(data: BackupService(context: destination).exportData())
        XCTAssertEqual(reexported.foodEntries.count, validated.foodEntries.count)
        XCTAssertEqual(reexported.target, validated.target)
    }

    func testMergeSkipsEntriesAlreadyPresent() throws {
        let context = TestSupport.makeContext()
        seed(context)
        let file = try BackupService.validate(data: BackupService(context: context).exportData())
        let summary = try BackupService(context: context).importBackup(file, strategy: .merge)
        XCTAssertEqual(summary.entriesImported, 0)
        XCTAssertEqual(summary.entriesSkipped, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FoodEntry>()).count, 2)
    }

    func testNewerSchemaVersionRejectedBeforeDecoding() {
        let json = #"{"schemaVersion": 99, "exportDate": "2030-01-01T00:00:00Z", "somethingNew": true}"#
        XCTAssertThrowsError(try BackupService.validate(data: Data(json.utf8))) { error in
            XCTAssertEqual(error as? BackupError,
                           .unsupportedVersion(found: 99, supported: BackupFile.currentSchemaVersion))
        }
    }

    func testNonBackupJSONRejected() {
        XCTAssertThrowsError(try BackupService.validate(data: Data(#"{"hello": "world"}"#.utf8))) {
            XCTAssertEqual($0 as? BackupError, .notABackup)
        }
        XCTAssertThrowsError(try BackupService.validate(data: Data("not json".utf8))) {
            XCTAssertEqual($0 as? BackupError, .notABackup)
        }
    }

    func testCorruptPayloadRejected() {
        let json = #"{"schemaVersion": 1, "exportDate": "2026-10-01T00:00:00Z", "foodEntries": "oops", "barcodeCache": []}"#
        XCTAssertThrowsError(try BackupService.validate(data: Data(json.utf8))) { error in
            guard case .corruptPayload = error as? BackupError else {
                return XCTFail("expected corruptPayload, got \(error)")
            }
        }
    }

    func testSemanticValidationCatchesBadValues() {
        let bad = BackupFile(foodEntries: [FoodEntryDTO(
            id: UUID(), name: "Bad", consumedAt: .now, quantity: -1, servingSize: 1,
            unit: "gram", nutritionPerServing: .zero, ingredients: [], source: "manual",
            photoPath: nil, barcode: nil, createdAt: .now, updatedAt: .now)])
        XCTAssertThrowsError(try BackupService.validateContents(bad))

        let unknownUnit = BackupFile(foodEntries: [FoodEntryDTO(
            id: UUID(), name: "Bad", consumedAt: .now, quantity: 1, servingSize: 1,
            unit: "bucket", nutritionPerServing: .zero, ingredients: [], source: "manual",
            photoPath: nil, barcode: nil, createdAt: .now, updatedAt: .now)])
        XCTAssertThrowsError(try BackupService.validateContents(unknownUnit))
    }

    /// A failed validation must leave the live store untouched.
    func testInvalidImportDoesNotTouchLiveData() throws {
        let context = TestSupport.makeContext()
        seed(context)
        XCTAssertThrowsError(try BackupService.validate(data: Data("garbage".utf8)))
        XCTAssertEqual(try context.fetch(FetchDescriptor<FoodEntry>()).count, 2)
    }
}
