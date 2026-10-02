import XCTest
@testable import NutritionTracker

final class NutritionArithmeticTests: XCTestCase {

    func testAdditionAndScaling() {
        let a = Nutrition(calories: 100, protein: 10, carbs: 5, fat: 2, fibre: 1)
        let b = Nutrition(calories: 50, protein: 5, carbs: 5, fat: 1, fibre: 1)
        XCTAssertEqual(a + b, Nutrition(calories: 150, protein: 15, carbs: 10, fat: 3, fibre: 2))
        XCTAssertEqual(a * 2, Nutrition(calories: 200, protein: 20, carbs: 10, fat: 4, fibre: 2))
    }

    func testScalingByNonFiniteFactorYieldsZero() {
        XCTAssertEqual(Nutrition(calories: 100) * .infinity, .zero)
        XCTAssertEqual(Nutrition(calories: 100) * .nan, .zero)
    }

    func testSanitiseRemovesNaNAndNegatives() {
        let dirty = Nutrition(calories: .nan, protein: -5, carbs: 10, fat: .infinity)
        XCTAssertFalse(dirty.isValid)
        let clean = dirty.sanitised
        XCTAssertTrue(clean.isValid)
        XCTAssertEqual(clean.calories, 0)
        XCTAssertEqual(clean.protein, 0)
        XCTAssertEqual(clean.carbs, 10)
    }

    func testScaleFactorGuardsZeroServing() {
        XCTAssertEqual(NutritionMath.scaleFactor(quantity: 2, servingSize: 0), 0)
        XCTAssertEqual(NutritionMath.scaleFactor(quantity: -1, servingSize: 1), 0)
        XCTAssertEqual(NutritionMath.scaleFactor(quantity: 150, servingSize: 100), 1.5)
    }

    // MARK: Simple food

    func testSimpleFoodScalesWithQuantity() {
        // Whey: 120 kcal per 1 scoop, logging 1.5 scoops.
        let shake = FoodEntry(name: "Whey Protein Shake", quantity: 1.5, servingSize: 1,
                              unit: .scoop,
                              nutritionPerServing: Nutrition(calories: 120, protein: 24,
                                                             carbs: 3, fat: 1.5))
        XCTAssertFalse(shake.isComposite)
        XCTAssertEqual(shake.total.calories, 180, accuracy: 0.001)
        XCTAssertEqual(shake.total.protein, 36, accuracy: 0.001)
    }

    func testGramBasedSimpleFood() {
        let rice = FoodEntry(name: "Rice", quantity: 250, servingSize: 100, unit: .gram,
                             nutritionPerServing: Nutrition(calories: 130, carbs: 28))
        XCTAssertEqual(rice.total.calories, 325, accuracy: 0.001)
    }

    // MARK: Composite food

    private func nasiLemak(parentQuantity: Double = 1) -> FoodEntry {
        let rice = IngredientItem(name: "Coconut rice", quantity: 200, servingSize: 100,
                                  unit: .gram,
                                  nutritionPerServing: Nutrition(calories: 180, protein: 3,
                                                                 carbs: 28, fat: 6))
        let egg = IngredientItem(name: "Fried egg", quantity: 1, servingSize: 1, unit: .piece,
                                 nutritionPerServing: Nutrition(calories: 90, protein: 6,
                                                                carbs: 0.4, fat: 7))
        let sambal = IngredientItem(name: "Sambal", quantity: 2, servingSize: 1,
                                    unit: .tablespoon,
                                    nutritionPerServing: Nutrition(calories: 40, protein: 0.5,
                                                                   carbs: 3, fat: 3))
        return FoodEntry(name: "Nasi Lemak", quantity: parentQuantity, servingSize: 1,
                         unit: .serving,
                         // Deliberately non-zero: a composite food must ignore it.
                         nutritionPerServing: Nutrition(calories: 9999),
                         ingredients: [rice, egg, sambal])
    }

    func testCompositeTotalIsSumOfIngredients() {
        let meal = nasiLemak()
        XCTAssertTrue(meal.isComposite)
        // 360 + 90 + 80
        XCTAssertEqual(meal.total.calories, 530, accuracy: 0.001)
        XCTAssertEqual(meal.total.protein, 6 + 6 + 1, accuracy: 0.001)
    }

    func testCompositeIgnoresParentOwnNutrition() {
        XCTAssertNotEqual(nasiLemak().total.calories, 9999)
    }

    func testParentQuantityScalesWholeComposite() {
        XCTAssertEqual(nasiLemak(parentQuantity: 2).total.calories, 1060, accuracy: 0.001)
        XCTAssertEqual(nasiLemak(parentQuantity: 0.5).total.calories, 265, accuracy: 0.001)
    }

    func testChangingIngredientQuantityUpdatesParent() {
        let meal = nasiLemak()
        meal.ingredients.first { $0.name == "Coconut rice" }!.quantity = 100 // halve the rice
        XCTAssertEqual(meal.total.calories, 530 - 180, accuracy: 0.001)
    }

    // MARK: Drafts

    func testDraftCompositeMatchesEntry() {
        let meal = nasiLemak()
        let draft = FoodEntryDraft(entry: meal)
        XCTAssertEqual(draft.total, meal.total)
        XCTAssertEqual(draft.makeEntry().total, meal.total)
    }

    func testDraftSaveability() {
        var draft = FoodEntryDraft(name: "", nutritionPerServing: Nutrition(calories: 100))
        XCTAssertFalse(draft.isSaveable, "needs a name")
        draft.name = "Toast"
        XCTAssertTrue(draft.isSaveable)
        draft.quantity = 0
        XCTAssertFalse(draft.isSaveable, "zero quantity is not saveable")
        draft.quantity = 1
        draft.nutritionPerServing = .zero
        XCTAssertFalse(draft.isSaveable, "all-zero nutrition is almost always an accident")
    }

    func testDraftApplyReusesIngredientRowsAndKeepsOrder() {
        let meal = FoodEntryDraft(name: "Nasi Lemak", ingredients: [
            IngredientDraft(name: "Coconut rice", quantity: 200, servingSize: 100),
            IngredientDraft(name: "Fried egg", quantity: 1, servingSize: 1, unit: .piece),
            IngredientDraft(name: "Sambal", quantity: 2, servingSize: 1, unit: .tablespoon)
        ]).makeEntry()
        XCTAssertEqual(meal.orderedIngredients.map(\.position), [0, 1, 2])

        let originalEggID = meal.orderedIngredients[1].id
        var draft = FoodEntryDraft(entry: meal)
        draft.ingredients[1].quantity = 2
        draft.ingredients.remove(at: 2)
        draft.ingredients.append(IngredientDraft(name: "Cucumber", quantity: 30,
                                                 servingSize: 100, unit: .gram))
        draft.apply(to: meal)

        let ordered = meal.orderedIngredients
        XCTAssertEqual(ordered.map(\.name), ["Coconut rice", "Fried egg", "Cucumber"])
        XCTAssertEqual(ordered[1].id, originalEggID, "existing row reused")
        XCTAssertEqual(ordered[1].quantity, 2)
    }

    // MARK: Quantity stepper

    func testStepperRoundsToCleanSteps() {
        // 0.1 + 0.2 style floating-point noise must not leak into the UI.
        XCTAssertEqual(QuantityStepper.rounded(0.30000000000000004, unit: .scoop), 0.5)
        XCTAssertEqual(QuantityStepper.rounded(1.5, unit: .scoop), 1.5)
        XCTAssertEqual(QuantityStepper.rounded(104, unit: .gram), 100)
        XCTAssertEqual(QuantityStepper.rounded(-10, unit: .gram), 0, "never negative")
        XCTAssertEqual(QuantityStepper.rounded(.nan, unit: .piece), 0)
    }

    func testUnitIncrements() {
        XCTAssertEqual(ServingUnit.piece.step, 1)
        XCTAssertEqual(ServingUnit.gram.step, 10)
        XCTAssertEqual(ServingUnit.gram.coarseStep, 25)
        XCTAssertEqual(ServingUnit.millilitre.step, 25)
        XCTAssertEqual(ServingUnit.millilitre.coarseStep, 50)
        XCTAssertEqual(ServingUnit.scoop.step, 0.5)
    }

    func testIngredientLowConfidenceFlag() {
        let low = IngredientItem(name: "Unknown", confidence: 0.43)
        let high = IngredientItem(name: "Rice", confidence: 0.91)
        let manual = IngredientItem(name: "Typed")
        XCTAssertTrue(low.isLowConfidence)
        XCTAssertFalse(high.isLowConfidence)
        XCTAssertFalse(manual.isLowConfidence, "no confidence means user-entered")
    }
}
