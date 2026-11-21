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

    /// The photo model's label map must ship with the app.
    func testBundledOntologyLoads() {
        XCTAssertFalse(FoodOntology.loadBundled().isEmpty, "ontology.json missing from the app bundle")
    }
}

/// With no food table, a photo's nutrition comes from the portion model's
/// whole-plate estimate, split across the foods by mass.
@MainActor
final class NutritionResolutionTests: XCTestCase {

    private func repository() -> NutritionRepository {
        NutritionRepository(context: TestSupport.makeContext())
    }

    private func detection(_ name: String, canonical: String?, confidence: Double = 0.9) -> DetectedIngredient {
        DetectedIngredient(rawLabel: name, canonicalID: canonical, displayName: name,
                           confidence: confidence)
    }

    func testPlateEstimateIsSplitByMass() {
        let rice = detection("White Rice", canonical: "gen.rice.white_cooked")
        let curry = detection("Curry", canonical: nil, confidence: 0.4)
        let resolved = repository().resolve(
            detections: [rice, curry],
            portions: [
                PortionEstimate(detectionID: rice.id, estimatedGrams: 200, confidence: 0.9),
                PortionEstimate(detectionID: curry.id, estimatedGrams: 100, confidence: 0.4)
            ],
            wholePlateNutrition: Nutrition(calories: 600, protein: 30, carbs: 60, fat: 21))

        XCTAssertEqual(resolved[0].total.calories, 400, accuracy: 0.01, "two thirds of the mass")
        XCTAssertEqual(resolved[1].total.calories, 200, accuracy: 0.01)
        XCTAssertTrue(resolved.allSatisfy { $0.provenance == .modelEstimate })
        XCTAssertEqual(resolved[0].canonicalID, "gen.rice.white_cooked", "label mapping kept")
    }

    func testWithoutPlateEstimateEverythingIsZeroForTheUserToFill() {
        let mystery = detection("Mystery", canonical: nil)
        let resolved = repository().resolve(detections: [mystery], portions: [],
                                            wholePlateNutrition: nil)
        XCTAssertEqual(resolved[0].nutritionPer100g, .zero)
        XCTAssertEqual(resolved[0].provenance, .modelEstimate)
    }

    func testNoMassesSplitEvenly() {
        let a = detection("A", canonical: nil), b = detection("B", canonical: nil)
        let resolved = repository().resolve(detections: [a, b], portions: [],
                                            wholePlateNutrition: Nutrition(calories: 300))
        // No grams to scale by: per-100 g stays zero rather than dividing by 0.
        XCTAssertEqual(resolved.count, 2)
        XCTAssertTrue(resolved.allSatisfy { $0.nutritionPer100g.calories.isFinite })
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
                                   modelBIdentifier: "B", portionsEstimated: true,
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

    func testModelUnavailableErrorIsIdentifiable() {
        XCTAssertTrue(AIServiceError.modelUnavailable(name: "X").isModelUnavailable)
        XCTAssertFalse(AIServiceError.invalidImage.isModelUnavailable)
    }

    func testUnavailableModelsReportHonestly() async {
        XCTAssertFalse(UnavailableIngredientRecognitionService().isAvailable)
        XCTAssertFalse(UnavailablePortionNutritionService().isAvailable)
        XCTAssertFalse(ModelCatalogue.isPresent("DefinitelyNotAModel"))
    }
}
