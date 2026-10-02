import XCTest
@testable import NutritionTracker

final class NutritionTargetCalculatorTests: XCTestCase {

    // Reference subject: male, 80 kg, 180 cm, 30 years.
    // BMR = 10*80 + 6.25*180 - 5*30 + 5 = 1780
    private func referenceBreakdown(goal: FitnessGoal = .maintain,
                                    activity: ActivityLevel = .moderate,
                                    sex: BiologicalSex = .male)
        -> NutritionTargetCalculator.Breakdown {
        NutritionTargetCalculator.calculate(weightKg: 80, heightCm: 180, age: 30,
                                            sex: sex, goal: goal, activity: activity)
    }

    func testMifflinStJeorMale() {
        XCTAssertEqual(NutritionTargetCalculator.basalMetabolicRate(
            weightKg: 80, heightCm: 180, age: 30, sex: .male), 1780, accuracy: 0.001)
    }

    func testMifflinStJeorFemaleUsesFemaleConstant() {
        // 10*60 + 6.25*165 - 5*28 - 161 = 1330.25
        XCTAssertEqual(NutritionTargetCalculator.basalMetabolicRate(
            weightKg: 60, heightCm: 165, age: 28, sex: .female), 1330.25, accuracy: 0.001)
    }

    func testTDEEAppliesActivityMultiplier() {
        let breakdown = referenceBreakdown()
        XCTAssertEqual(breakdown.tdee, 1780 * 1.55, accuracy: 0.001)
    }

    func testMaintainCalorieBandIsSymmetricAroundPointEstimate() {
        let breakdown = referenceBreakdown()
        // Point = round(2759) = 2759; band = +/-7.5%.
        XCTAssertEqual(breakdown.caloriePointEstimate, 2759)
        XCTAssertEqual(breakdown.ranges.calories.min, (2759 * 0.925).rounded())
        XCTAssertEqual(breakdown.ranges.calories.max, (2759 * 1.075).rounded())
        XCTAssertLessThan(breakdown.ranges.calories.min, breakdown.caloriePointEstimate)
        XCTAssertGreaterThan(breakdown.ranges.calories.max, breakdown.caloriePointEstimate)
    }

    func testGoalOrderingDeficitToSurplus() {
        let lose = referenceBreakdown(goal: .loseWeight).caloriePointEstimate
        let recomp = referenceBreakdown(goal: .recomposition).caloriePointEstimate
        let maintain = referenceBreakdown(goal: .maintain).caloriePointEstimate
        let build = referenceBreakdown(goal: .buildMuscle).caloriePointEstimate
        XCTAssertLessThan(lose, recomp, "weight loss must be a larger deficit than recomposition")
        XCTAssertLessThan(recomp, maintain)
        XCTAssertLessThan(maintain, build)
    }

    func testProteinUsesGuidelineRangeDirectlyNotAMidpoint() {
        let breakdown = referenceBreakdown(goal: .buildMuscle)
        let perKg = NutritionConstants.proteinRangeBuildMuscle
        XCTAssertEqual(breakdown.ranges.protein.min, (80 * perKg.min).rounded())
        XCTAssertEqual(breakdown.ranges.protein.max, (80 * perKg.max).rounded())
    }

    func testFatRespectsPerKgFloor() {
        // Low calorie subject so the energy share falls below the per-kg floor.
        let breakdown = NutritionTargetCalculator.calculate(
            weightKg: 120, heightCm: 150, age: 70, sex: .female,
            goal: .loseWeight, activity: .sedentary)
        let floor = 120 * NutritionConstants.fatMinimumGramsPerKg
        XCTAssertGreaterThanOrEqual(breakdown.ranges.fat.max, floor.rounded())
        XCTAssertEqual(breakdown.ranges.fat.midpoint, floor.rounded(), accuracy: 1)
    }

    func testCarbBandIsDerivedConsistentlyFromCalorieBand() {
        let ranges = referenceBreakdown().ranges
        let expectedMin = NutritionTargetCalculator.remainingCarbGrams(
            calories: ranges.calories.min, proteinGrams: ranges.protein.max,
            fatGrams: ranges.fat.max)
        let expectedMax = NutritionTargetCalculator.remainingCarbGrams(
            calories: ranges.calories.max, proteinGrams: ranges.protein.min,
            fatGrams: ranges.fat.min)
        XCTAssertEqual(ranges.carbs.min, expectedMin)
        XCTAssertEqual(ranges.carbs.max, expectedMax)
        XCTAssertLessThan(ranges.carbs.min, ranges.carbs.max)
    }

    func testCarbsNeverNegative() {
        XCTAssertEqual(NutritionTargetCalculator.remainingCarbGrams(
            calories: 1000, proteinGrams: 200, fatGrams: 100), 0)
    }

    func testFibreFollowsCalorieGuidelineWithBand() {
        let breakdown = referenceBreakdown()
        let point = (breakdown.caloriePointEstimate / 1000 * 14).rounded()
        XCTAssertEqual(breakdown.ranges.fibre.midpoint, point, accuracy: 1)
        XCTAssertGreaterThan(breakdown.ranges.fibre.width, 0)
    }

    func testCalorieFloorApplies() {
        let breakdown = NutritionTargetCalculator.calculate(
            weightKg: 40, heightCm: 145, age: 80, sex: .female,
            goal: .loseWeight, activity: .sedentary)
        XCTAssertEqual(breakdown.caloriePointEstimate, NutritionConstants.minimumCalorieFloor)
    }

    /// Strength/cardio counts are profile context only; the activity multiplier
    /// already includes exercise (spec section 6).
    func testTrainingSessionsDoNotDoubleCountExercise() {
        let dob = Calendar(identifier: .gregorian).date(byAdding: .year, value: -30, to: .now)!
        let none = UserProfile(dateOfBirth: dob, sex: .male, heightCm: 180, weightKg: 80,
                               goal: .maintain, activity: .moderate,
                               strengthSessionsPerWeek: 0, cardioSessionsPerWeek: 0)
        let lots = UserProfile(dateOfBirth: dob, sex: .male, heightCm: 180, weightKg: 80,
                               goal: .maintain, activity: .moderate,
                               strengthSessionsPerWeek: 6, cardioSessionsPerWeek: 5)
        XCTAssertEqual(NutritionTargetCalculator.calculate(profile: none).ranges,
                       NutritionTargetCalculator.calculate(profile: lots).ranges)
    }

    func testAllBandsWellFormed() {
        for goal in FitnessGoal.allCases {
            for activity in ActivityLevel.allCases {
                let ranges = referenceBreakdown(goal: goal, activity: activity).ranges
                for nutrient in Nutrient.allCases {
                    XCTAssertLessThanOrEqual(ranges[nutrient].min, ranges[nutrient].max,
                                             "\(nutrient) for \(goal)/\(activity)")
                    XCTAssertGreaterThanOrEqual(ranges[nutrient].min, 0)
                }
            }
        }
    }
}
