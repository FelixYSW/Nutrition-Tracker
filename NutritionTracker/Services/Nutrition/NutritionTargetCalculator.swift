import Foundation

/// Every tunable number used by the nutrition engine, in one place.
///
/// Nothing here is a magic number buried in a formula: each constant is named,
/// documented and unit-tested so the reasoning stays auditable (spec section 6).
enum NutritionConstants {

    // MARK: Mifflin-St Jeor BMR coefficients
    //
    // BMR = 10 * kg + 6.25 * cm - 5 * years + sexConstant
    static let bmrWeightCoefficient: Double = 10.0
    static let bmrHeightCoefficient: Double = 6.25
    static let bmrAgeCoefficient: Double = 5.0
    static let bmrMaleConstant: Double = 5.0
    static let bmrFemaleConstant: Double = -161.0

    // MARK: Goal-based energy adjustment
    //
    // Applied to TDEE. A deficit/surplus expressed as a multiplier keeps the
    // adjustment proportional to body size rather than a flat calorie figure.
    static let loseWeightMultiplier: Double = 0.80      // ~20% deficit
    static let recompositionMultiplier: Double = 0.92   // ~8% deficit, smaller by design
    static let maintainMultiplier: Double = 1.00
    static let buildMuscleMultiplier: Double = 1.10     // ~10% surplus

    /// Hard floor so an aggressive deficit on a small frame cannot produce an
    /// unreasonably low calorie target.
    static let minimumCalorieFloor: Double = 1200

    // MARK: Band widths (v2)
    //
    // The spec requires targets to be ranges, because BMR/TDEE prediction error
    // is real: Mifflin-St Jeor typically lands within roughly +/-10% of measured
    // RMR for most people, and TDEE adds further activity-estimate error on top.
    // A +/-7.5% calorie band is a deliberate, documented compromise: wide enough
    // to be honest about the error, narrow enough to still be actionable.
    static let calorieBandFraction: Double = 0.075

    /// Fat and fibre have no published range as tight as protein's, so they get
    /// a derived band of the same shape as calories.
    static let fatBandFraction: Double = 0.15
    static let fibreBandFraction: Double = 0.15

    /// Carbs absorb the remaining energy, so their band is derived from the
    /// calorie band rather than given its own fraction.

    // MARK: Protein
    //
    // Expressed directly as the evidence-based g/kg range rather than collapsed
    // to a midpoint, per the spec: where the underlying guideline is already a
    // range, use it. Figures follow common sports-nutrition guidance of roughly
    // 1.6-2.2 g/kg for trainees, with the top of the band used in a deficit
    // where protein needs rise to protect lean mass.
    static let proteinRangeLoseWeight: (min: Double, max: Double) = (1.8, 2.4)
    static let proteinRangeRecomposition: (min: Double, max: Double) = (1.8, 2.4)
    static let proteinRangeMaintain: (min: Double, max: Double) = (1.4, 1.8)
    static let proteinRangeBuildMuscle: (min: Double, max: Double) = (1.6, 2.2)

    // MARK: Fat
    //
    // A floor to protect hormone and fat-soluble-vitamin needs, plus a
    // percentage-of-energy figure; the larger of the two is used.
    static let fatMinimumGramsPerKg: Double = 0.6
    static let fatEnergyFraction: Double = 0.25
    static let caloriesPerGramFat: Double = 9
    static let caloriesPerGramProtein: Double = 4
    static let caloriesPerGramCarb: Double = 4

    // MARK: Fibre
    //
    // Common dietary guideline of ~14 g per 1000 kcal.
    static let fibreGramsPerThousandCalories: Double = 14

    // MARK: Misc
    /// Detections below this confidence are flagged for review in the UI.
    static let lowConfidenceThreshold: Double = 0.60

    /// Weight drift that makes stored targets worth recalculating.
    static let weightChangeRecalcThresholdKg: Double = 3.0
}

/// Deterministic daily-target maths. No AI anywhere in this file (spec section 6).
enum NutritionTargetCalculator {

    /// Intermediate figures, exposed so the UI can explain where a target came
    /// from and so tests can assert each stage independently.
    struct Breakdown: Equatable, Sendable {
        var age: Int
        var bmr: Double
        var tdee: Double
        var goalMultiplier: Double
        /// Calorie point estimate before the band is applied.
        var caloriePointEstimate: Double
        var ranges: NutritionTargetRanges
    }

    // MARK: BMR / TDEE

    static func basalMetabolicRate(weightKg: Double, heightCm: Double,
                                   age: Int, sex: BiologicalSex) -> Double {
        let sexConstant = sex == .male
            ? NutritionConstants.bmrMaleConstant
            : NutritionConstants.bmrFemaleConstant
        return NutritionConstants.bmrWeightCoefficient * weightKg
            + NutritionConstants.bmrHeightCoefficient * heightCm
            - NutritionConstants.bmrAgeCoefficient * Double(age)
            + sexConstant
    }

    static func totalDailyEnergyExpenditure(bmr: Double, activity: ActivityLevel) -> Double {
        // Activity multiplier already includes exercise; strength/cardio session
        // counts are NOT added here, which is what avoids double-counting.
        bmr * activity.multiplier
    }

    static func goalMultiplier(for goal: FitnessGoal) -> Double {
        switch goal {
        case .loseWeight: NutritionConstants.loseWeightMultiplier
        case .recomposition: NutritionConstants.recompositionMultiplier
        case .maintain: NutritionConstants.maintainMultiplier
        case .buildMuscle: NutritionConstants.buildMuscleMultiplier
        }
    }

    static func proteinGramsPerKg(for goal: FitnessGoal) -> (min: Double, max: Double) {
        switch goal {
        case .loseWeight: NutritionConstants.proteinRangeLoseWeight
        case .recomposition: NutritionConstants.proteinRangeRecomposition
        case .maintain: NutritionConstants.proteinRangeMaintain
        case .buildMuscle: NutritionConstants.proteinRangeBuildMuscle
        }
    }

    // MARK: Entry points

    static func calculate(profile: UserProfile,
                          now: Date = .now,
                          calendar: Calendar = .autoupdatingCurrent) -> Breakdown {
        calculate(weightKg: profile.weightKg,
                  heightCm: profile.heightCm,
                  age: profile.age(on: now, calendar: calendar),
                  sex: profile.sex,
                  goal: profile.goal,
                  activity: profile.activity)
    }

    static func calculate(weightKg: Double,
                          heightCm: Double,
                          age: Int,
                          sex: BiologicalSex,
                          goal: FitnessGoal,
                          activity: ActivityLevel) -> Breakdown {

        let safeWeight = max(1, weightKg)
        let bmr = basalMetabolicRate(weightKg: safeWeight, heightCm: max(1, heightCm),
                                     age: max(1, age), sex: sex)
        let tdee = totalDailyEnergyExpenditure(bmr: bmr, activity: activity)
        let multiplier = goalMultiplier(for: goal)
        let caloriePoint = max(NutritionConstants.minimumCalorieFloor,
                               (tdee * multiplier).rounded())

        // --- Calories: band around the point estimate.
        let calorieRange = NutrientRange.band(around: caloriePoint,
                                              fraction: NutritionConstants.calorieBandFraction)

        // --- Protein: the guideline is already a range, so use it directly
        //     instead of collapsing to a midpoint.
        let proteinPerKg = proteinGramsPerKg(for: goal)
        let proteinRange = NutrientRange(min: (safeWeight * proteinPerKg.min).rounded(),
                                         max: (safeWeight * proteinPerKg.max).rounded())

        // --- Fat: the larger of a per-kg floor and a share of energy, banded.
        let fatFromWeight = safeWeight * NutritionConstants.fatMinimumGramsPerKg
        let fatFromEnergy = caloriePoint * NutritionConstants.fatEnergyFraction
            / NutritionConstants.caloriesPerGramFat
        let fatPoint = max(fatFromWeight, fatFromEnergy).rounded()
        let fatRange = NutrientRange.band(around: fatPoint,
                                          fraction: NutritionConstants.fatBandFraction)

        // --- Carbs: remaining energy once protein and fat are accounted for.
        //     The band is derived from the calorie band, so the lower carb bound
        //     pairs the lower calorie bound with the *higher* protein/fat demand
        //     and vice versa. That keeps the three macro bands mutually
        //     consistent instead of independently banded.
        let carbsMin = remainingCarbGrams(calories: calorieRange.min,
                                          proteinGrams: proteinRange.max,
                                          fatGrams: fatRange.max)
        let carbsMax = remainingCarbGrams(calories: calorieRange.max,
                                          proteinGrams: proteinRange.min,
                                          fatGrams: fatRange.min)
        let carbRange = NutrientRange(min: carbsMin, max: carbsMax)

        // --- Fibre: calorie-based guideline, banded.
        let fibrePoint = (caloriePoint / 1000
            * NutritionConstants.fibreGramsPerThousandCalories).rounded()
        let fibreRange = NutrientRange.band(around: fibrePoint,
                                            fraction: NutritionConstants.fibreBandFraction)

        let ranges = NutritionTargetRanges(calories: calorieRange,
                                           protein: proteinRange,
                                           carbs: carbRange,
                                           fat: fatRange,
                                           fibre: fibreRange)

        return Breakdown(age: max(1, age),
                         bmr: bmr,
                         tdee: tdee,
                         goalMultiplier: multiplier,
                         caloriePointEstimate: caloriePoint,
                         ranges: ranges)
    }

    /// Energy left for carbohydrate after protein and fat, floored at zero so an
    /// extreme protein/fat combination cannot produce a negative carb target.
    static func remainingCarbGrams(calories: Double,
                                   proteinGrams: Double,
                                   fatGrams: Double) -> Double {
        let used = proteinGrams * NutritionConstants.caloriesPerGramProtein
            + fatGrams * NutritionConstants.caloriesPerGramFat
        return max(0, ((calories - used) / NutritionConstants.caloriesPerGramCarb).rounded())
    }
}
