import XCTest
import SwiftData
@testable import NutritionTracker

/// Fixed reference data so these tests do not depend on what is bundled.
enum ReferenceFixtures {
    static let ontology = FoodOntology(entries: [
        .init(canonicalID: "gen.rice.white_cooked", displayName: "White Rice",
              aliases: ["rice", "nasi putih", "white_rice"], sources: ["foodseg103"], isMalaysian: false),
        .init(canonicalID: "my.rice.coconut", displayName: "Coconut Rice",
              aliases: ["coconut rice", "nasi lemak rice"], sources: ["mf150"], isMalaysian: true),
        .init(canonicalID: "gen.egg.fried", displayName: "Fried Egg",
              aliases: ["fried egg", "telur goreng"], sources: ["mf150"], isMalaysian: false)
    ])

    static let table = LocalNutritionReference(rows: [
        .init(canonicalID: "gen.rice.white_cooked", displayName: "White Rice",
              calories: 130, protein: 2.7, carbs: 28.2, fat: 0.3, fibre: 0.4,
              source: "generic"),
        .init(canonicalID: "my.rice.coconut", displayName: "Coconut Rice",
              calories: 180, protein: 3, carbs: 28, fat: 6,
              source: "myfcd", sourceCode: "TEST-001"),
        .init(canonicalID: "gen.egg.fried", displayName: "Fried Egg",
              calories: 196, protein: 13.6, carbs: 0.8, fat: 15.3, source: "generic")
    ])
}

final class FoodOntologyTests: XCTestCase {

    func testAliasesResolveToOneCanonicalID() {
        let ontology = ReferenceFixtures.ontology
        XCTAssertEqual(ontology.resolve(rawLabel: "rice")?.canonicalID, "gen.rice.white_cooked")
        XCTAssertEqual(ontology.resolve(rawLabel: "Nasi Putih")?.canonicalID, "gen.rice.white_cooked")
        XCTAssertEqual(ontology.resolve(rawLabel: "white_rice")?.canonicalID, "gen.rice.white_cooked")
    }

    func testUnderscoreAndHyphenNormalisation() {
        XCTAssertEqual(ReferenceFixtures.ontology.resolve(rawLabel: "fried_egg")?.canonicalID, "gen.egg.fried")
        XCTAssertEqual(ReferenceFixtures.ontology.resolve(rawLabel: "fried-egg")?.canonicalID, "gen.egg.fried")
    }

    /// Coconut rice must not silently merge into plain rice: the fat differs a lot.
    func testDistinctFoodsAreNotMergedBlindly() {
        XCTAssertNotEqual(ReferenceFixtures.ontology.resolve(rawLabel: "coconut rice")?.canonicalID,
                          ReferenceFixtures.ontology.resolve(rawLabel: "rice")?.canonicalID)
    }

    func testUnknownLabelReturnsNil() {
        XCTAssertNil(ReferenceFixtures.ontology.resolve(rawLabel: "dragon fruit sorbet"))
    }

    func testMalformedOntologyFallsBackToEmpty() {
        XCTAssertTrue(FoodOntology.load(data: Data("{oops".utf8)).isEmpty)
    }

    func testSearchPrefersPrefixMatches() {
        XCTAssertEqual(ReferenceFixtures.ontology.search("rice").count, 2)
        // "Coconut" sorts first alphabetically, but "White" is the prefix match.
        XCTAssertEqual(ReferenceFixtures.ontology.search("whi").first?.displayName, "White Rice")
        XCTAssertEqual(ReferenceFixtures.ontology.search("rice").first?.displayName, "Coconut Rice",
                       "no prefix match: alphabetical")
    }

    /// The bundled files must parse and stay consistent with each other.
    func testBundledReferenceDataIsConsistent() {
        let ontology = FoodOntology.loadBundled()
        let table = LocalNutritionReference.loadBundled()
        XCTAssertFalse(ontology.isEmpty, "ontology.json missing from the app bundle")
        XCTAssertFalse(table.isEmpty, "myfcd_reference.json missing from the app bundle")
        for row in table.allRows {
            XCTAssertNotNil(ontology.entry(canonicalID: row.canonicalID),
                            "\(row.canonicalID) has no ontology entry")
            XCTAssertTrue(row.nutritionPer100g.isValid)
        }
    }
}

final class LocalNutritionReferenceTests: XCTestCase {

    func testMyFCDRowLookupByCanonicalID() throws {
        let row = try XCTUnwrap(ReferenceFixtures.table.row(canonicalID: "my.rice.coconut"))
        XCTAssertEqual(row.provenance, .myFCD)
        XCTAssertEqual(row.sourceCode, "TEST-001")
        XCTAssertEqual(row.nutritionPer100g.calories, 180)
        XCTAssertEqual(row.nutritionPer100g.fat, 6)
    }

    func testGenericRowProvenance() {
        XCTAssertEqual(ReferenceFixtures.table.row(canonicalID: "gen.egg.fried")?.provenance,
                       .genericDatabase)
    }

    func testMissingOptionalNutrientsDefaultToZero() {
        XCTAssertEqual(ReferenceFixtures.table.row(canonicalID: "gen.egg.fried")?.nutritionPer100g.fibre, 0)
    }

    func testDecodesFileFormat() {
        let json = """
        {"version": 1, "rows": [{"canonicalID": "x", "displayName": "X",
          "calories": 100, "protein": 1, "carbs": 2, "fat": 3, "source": "myfcd"}]}
        """
        XCTAssertEqual(LocalNutritionReference.load(data: Data(json.utf8)).count, 1)
        XCTAssertTrue(LocalNutritionReference.load(data: Data("nope".utf8)).isEmpty)
    }
}

@MainActor
final class NutritionResolutionTests: XCTestCase {

    private func repository() -> NutritionRepository {
        NutritionRepository(context: TestSupport.makeContext(),
                            localTable: ReferenceFixtures.table,
                            ontology: ReferenceFixtures.ontology)
    }

    private func detection(_ name: String, canonical: String?, confidence: Double = 0.9) -> DetectedIngredient {
        DetectedIngredient(rawLabel: name, canonicalID: canonical, displayName: name,
                           confidence: confidence)
    }

    func testCanonicalMatchUsesReferenceTableNotModelPrediction() {
        let rice = detection("Coconut Rice", canonical: "my.rice.coconut")
        let resolved = repository().resolve(
            detections: [rice],
            portions: [PortionEstimate(detectionID: rice.id, estimatedGrams: 200, confidence: 0.8)],
            // A wildly different whole-plate prediction must be ignored here.
            wholePlateNutrition: Nutrition(calories: 5000))

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].provenance, .myFCD)
        XCTAssertEqual(resolved[0].total.calories, 360, accuracy: 0.001, "180 kcal/100g * 200 g")
    }

    func testNameFallsBackThroughOntology() {
        let typed = detection("telur goreng", canonical: nil)
        let resolved = repository().resolve(detections: [typed],
                                            portions: [PortionEstimate(detectionID: typed.id,
                                                                       estimatedGrams: 50,
                                                                       confidence: 0.9)],
                                            wholePlateNutrition: nil)
        XCTAssertEqual(resolved[0].canonicalID, "gen.egg.fried")
        XCTAssertEqual(resolved[0].total.calories, 98, accuracy: 0.001)
    }

    /// Tier 5: an unmatched item gets only the part of the plate prediction not
    /// already explained by matched items, so nothing is double-counted.
    func testUnmatchedItemsShareResidualOfPlatePrediction() {
        let rice = detection("White Rice", canonical: "gen.rice.white_cooked")
        let mystery = detection("Mystery Curry", canonical: nil, confidence: 0.4)
        let resolved = repository().resolve(
            detections: [rice, mystery],
            portions: [
                PortionEstimate(detectionID: rice.id, estimatedGrams: 200, confidence: 0.9),
                PortionEstimate(detectionID: mystery.id, estimatedGrams: 150, confidence: 0.4)
            ],
            wholePlateNutrition: Nutrition(calories: 700, protein: 25, carbs: 80, fat: 25))

        let riceRow = resolved[0], curryRow = resolved[1]
        XCTAssertEqual(riceRow.total.calories, 260, accuracy: 0.001)
        XCTAssertEqual(curryRow.provenance, .modelEstimate)
        XCTAssertEqual(curryRow.total.calories, 700 - 260, accuracy: 0.01)
        XCTAssertEqual(riceRow.total.calories + curryRow.total.calories, 700, accuracy: 0.01)
    }

    func testUnmatchedWithoutPlatePredictionIsZeroForUserToFill() {
        let mystery = detection("Mystery", canonical: nil)
        let resolved = repository().resolve(detections: [mystery], portions: [],
                                            wholePlateNutrition: nil)
        XCTAssertEqual(resolved[0].nutritionPer100g, .zero)
        XCTAssertEqual(resolved[0].provenance, .modelEstimate)
    }

    /// Tier 1: a user-entered product outranks the reference table.
    func testUserVerifiedFoodWinsOverReferenceTable() {
        let context = TestSupport.makeContext()
        context.insert(BarcodeProductCache(barcode: "1", name: "White Rice", servingSize: 100,
                                           unit: .gram,
                                           nutritionPerServing: Nutrition(calories: 111),
                                           isUserEntered: true))
        try? context.save()
        let repo = NutritionRepository(context: context, localTable: ReferenceFixtures.table,
                                       ontology: ReferenceFixtures.ontology)
        let hit = repo.lookup(canonicalID: "gen.rice.white_cooked", name: "White Rice")
        XCTAssertEqual(hit?.provenance, .localVerified)
        XCTAssertEqual(hit?.nutritionPer100g.calories, 111)
    }
}

final class PhotoAnalysisResultTests: XCTestCase {

    private func makeResult(_ items: [(String, Double, Double)]) -> PhotoAnalysisResult {
        let detections = items.map {
            DetectedIngredient(rawLabel: $0.0, canonicalID: nil, displayName: $0.0, confidence: $0.2)
        }
        let resolved = zip(detections, items).map { detection, item in
            ResolvedIngredientNutrition(detectionID: detection.id, displayName: item.0,
                                        canonicalID: nil, grams: item.1,
                                        nutritionPer100g: Nutrition(calories: 150, protein: 10),
                                        provenance: .genericDatabase, confidence: item.2)
        }
        return PhotoAnalysisResult(detections: detections, portions: [],
                                   wholePlateNutrition: nil, resolvedNutrition: resolved,
                                   photoPath: "abc.jpg", modelAIdentifier: "A",
                                   modelBIdentifier: "B", usedRemoteFallback: false,
                                   producedAt: .now)
    }

    func testMultipleDetectionsBecomeCompositeDraft() {
        let draft = makeResult([("Rice", 200, 0.94), ("Chicken", 120, 0.91), ("Unknown item", 40, 0.43)])
            .makeDraft()
        XCTAssertTrue(draft.isComposite)
        XCTAssertEqual(draft.source, .photoAI)
        XCTAssertEqual(draft.photoPath, "abc.jpg")
        XCTAssertEqual(draft.ingredients.count, 3)
        XCTAssertEqual(draft.ingredients[0].quantity, 200)
        XCTAssertEqual(draft.ingredients[0].unit, .gram)
        XCTAssertEqual(draft.ingredients[0].servingSize, 100)
        XCTAssertEqual(draft.total.calories, (200 + 120 + 40) * 1.5, accuracy: 0.001)
        XCTAssertNotNil(draft.predictionJSON, "prediction kept for the correction record")
    }

    func testLowConfidenceDetectionIsFlagged() {
        let draft = makeResult([("Rice", 200, 0.94), ("Unknown item", 40, 0.43)]).makeDraft()
        XCTAssertTrue(draft.hasLowConfidenceItems)
        XCTAssertTrue(draft.ingredients[1].isLowConfidence)
        XCTAssertFalse(draft.ingredients[0].isLowConfidence)
    }

    func testSingleDetectionBecomesSimpleFood() {
        let draft = makeResult([("Banana", 120, 0.88)]).makeDraft()
        XCTAssertFalse(draft.isComposite)
        XCTAssertEqual(draft.name, "Banana")
        XCTAssertEqual(draft.total.calories, 180, accuracy: 0.001)
    }

    func testZeroMassDefaultsToEditableHundredGrams() {
        let draft = makeResult([("Rice", 0, 0.9), ("Egg", 0, 0.9)]).makeDraft()
        XCTAssertEqual(draft.ingredients.map(\.quantity), [100, 100])
    }

    func testSuggestedNames() {
        XCTAssertEqual(PhotoAnalysisResult.suggestName(from: []), "Meal")
        XCTAssertEqual(PhotoAnalysisResult.suggestName(from: ["Rice", "Egg"]), "Rice and Egg")
        XCTAssertEqual(PhotoAnalysisResult.suggestName(from: ["Rice", "Egg", "Sambal", "Peanuts"]),
                       "Rice, Egg and 2 more")
    }

    func testResultDTORoundTripsThroughJSON() throws {
        let result = makeResult([("Rice", 200, 0.94)])
        let decoded = try JSONDecoder().decode(PhotoAnalysisResult.self,
                                               from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
    }

    func testAreaSplitDistributesMassByArea() {
        let a = DetectedIngredient(rawLabel: "a", displayName: "A", confidence: 0.9, areaFraction: 0.6)
        let b = DetectedIngredient(rawLabel: "b", displayName: "B", confidence: 0.9, areaFraction: 0.2)
        let portions = CoreMLPortionNutritionService.splitByArea(totalMass: 400, detections: [a, b])
        XCTAssertEqual(portions.map(\.estimatedGrams), [300, 100])
        XCTAssertTrue(CoreMLPortionNutritionService.splitByArea(totalMass: 400, detections: []).isEmpty)
    }

    /// Decoding of the Model A export format: one confidence and one area value
    /// per class, labels as canonical IDs, index 0 background.
    func testSegmentationSummaryDecoding() {
        let detections = CoreMLIngredientRecognitionService.detections(
            labels: ["background", "gen.rice.white_cooked", "gen.egg.fried", "my.rice.coconut", "raw.foodseg103.sauce"],
            confidence: [0.99, 0.94, 0.43, 0.80, 0.70],
            area: [0.50, 0.30, 0.08, 0.004, 0.05],
            ontology: ReferenceFixtures.ontology)

        XCTAssertEqual(detections.map(\.rawLabel),
                       ["gen.rice.white_cooked", "raw.foodseg103.sauce", "gen.egg.fried"],
                       "background dropped, tiny area dropped, sorted by confidence")
        XCTAssertEqual(detections[0].displayName, "White Rice")
        XCTAssertEqual(detections[0].canonicalID, "gen.rice.white_cooked")
        XCTAssertNil(detections[1].canonicalID, "unmapped class keeps its raw label")
        XCTAssertTrue(detections[2].isLowConfidence)
    }

    func testSegmentationSummaryToleratesMismatchedLengths() {
        let detections = CoreMLIngredientRecognitionService.detections(
            labels: ["background", "gen.egg.fried"], confidence: [0.9], area: [0.5, 0.5],
            ontology: ReferenceFixtures.ontology)
        XCTAssertTrue(detections.isEmpty)
    }

    func testRemoteFallbackJSONExtraction() {
        let fenced = "Here you go:\n```json\n{\"foods\": []}\n```"
        XCTAssertEqual(AnthropicRemoteVisionService.extractJSON(from: fenced), "{\"foods\": []}")
    }

    func testUnavailableModelsReportHonestly() async {
        XCTAssertFalse(UnavailableIngredientRecognitionService().isAvailable)
        XCTAssertFalse(UnavailablePortionNutritionService().isAvailable)
        XCTAssertFalse(ModelCatalogue.isPresent("DefinitelyNotAModel"))
    }
}
