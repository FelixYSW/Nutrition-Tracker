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
        // BMI just under 30, so the floor uses body weight.
        let breakdown = NutritionTargetCalculator.calculate(
            weightKg: 85, heightCm: 170, age: 70, sex: .female,
            goal: .loseWeight, activity: .sedentary)
        let floor = 85 * NutritionConstants.fatMinimumGramsPerKg
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
        // The floor holds for the whole range, not just its centre.
        XCTAssertGreaterThanOrEqual(breakdown.ranges.calories.min,
                                    NutritionConstants.minimumCalorieFloor)
    }

    func testMenHaveAHigherCalorieFloor() {
        let breakdown = NutritionTargetCalculator.calculate(
            weightKg: 50, heightCm: 155, age: 60, sex: .male,
            goal: .loseWeight, activity: .sedentary)
        XCTAssertGreaterThanOrEqual(breakdown.ranges.calories.min,
                                    NutritionConstants.minimumCalorieFloorMale)
        XCTAssertLessThanOrEqual(breakdown.ranges.calories.min, breakdown.ranges.calories.max)
    }

    /// Every day in a weight-loss range is a deficit, and every day in the
    /// muscle-gain range a surplus.
    func testRangesStayOnTheGoalsSideOfMaintenance() {
        for activity in ActivityLevel.allCases {
            for goal in [FitnessGoal.loseWeight, .recomposition] {
                let breakdown = referenceBreakdown(goal: goal, activity: activity)
                XCTAssertLessThan(breakdown.ranges.calories.max, breakdown.tdee,
                                  "\(goal)/\(activity)")
            }
            let build = referenceBreakdown(goal: .buildMuscle, activity: activity)
            XCTAssertGreaterThan(build.ranges.calories.min, build.tdee, "\(activity)")
        }
    }

    /// 22-year-old woman, 163 cm, 100 kg (BMI ~37.6), aiming for 60 kg:
    /// protein comes from the goal weight, and carbs keep a real minimum.
    func testHighBMIUsesGoalWeightForProtein() {
        let breakdown = NutritionTargetCalculator.calculate(
            weightKg: 100, heightCm: 163, age: 22, sex: .female,
            goal: .loseWeight, activity: .sedentary, targetWeightKg: 60)
        XCTAssertEqual(breakdown.proteinWeightKg, 60)
        XCTAssertEqual(breakdown.ranges.protein.min, 108)
        XCTAssertEqual(breakdown.ranges.protein.max, 144)
        XCTAssertGreaterThan(breakdown.ranges.carbs.min, 50,
                             "used to be 0 g with protein from total weight")
    }

    func testHighBMIWithoutGoalUsesBMI25Weight() {
        let breakdown = NutritionTargetCalculator.calculate(
            weightKg: 100, heightCm: 163, age: 22, sex: .female,
            goal: .loseWeight, activity: .sedentary)
        XCTAssertEqual(breakdown.proteinWeightKg, 25 * 1.63 * 1.63, accuracy: 0.01)
    }

    func testProteinReferenceWeightRules() {
        // Below BMI 30: body weight, whatever the goal.
        XCTAssertEqual(NutritionTargetCalculator.proteinReferenceWeight(
            weightKg: 80, heightCm: 180, targetWeightKg: 70), 80)
        // A goal above current weight is ignored.
        XCTAssertEqual(NutritionTargetCalculator.proteinReferenceWeight(
            weightKg: 100, heightCm: 163, targetWeightKg: 110), 25 * 1.63 * 1.63, accuracy: 0.01)
        // A very low goal is lifted to the BMI 18.5 weight.
        XCTAssertEqual(NutritionTargetCalculator.proteinReferenceWeight(
            weightKg: 100, heightCm: 163, targetWeightKg: 40), 18.5 * 1.63 * 1.63, accuracy: 0.01)
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

    func testCalorieBalanceIsPositiveForADeficit() {
        XCTAssertEqual(CalorieBalance.deficit(consumed: 1_600, maintenance: 2_100), 500)
        XCTAssertEqual(CalorieBalance.deficit(consumed: 2_300, maintenance: 2_100), -200)
    }
}
