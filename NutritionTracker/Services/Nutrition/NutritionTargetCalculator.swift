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
    /// unreasonably low calorie target. Applies to the whole range - its
    /// minimum too, not just the centre - and is higher for men, following
    /// the common "no lower than ~1,200 (women) / ~1,500 (men) kcal without
    /// supervision" guidance.
    static let minimumCalorieFloor: Double = 1200
    static let minimumCalorieFloorMale: Double = 1500

    /// Weight-loss ranges stay below maintenance, and the muscle-gain range
    /// above it, so every day "in range" moves towards the goal. Without
    /// this the +/-7.5% band put the top of recomposition at ~99% of
    /// maintenance and the bottom of muscle gain at ~102%.
    static let deficitCeilingFraction: Double = 0.97
    static let surplusFloorFraction: Double = 1.03

    // MARK: Weight used for protein and the fat floor
    //
    // Per-kg guidance assumes a typical body composition. At a BMI of 30 or
    // more, total weight overstates lean mass, and 1.8-2.4 g/kg of it gave
    // e.g. 180-240 g of protein at 100 kg - more than needed, and enough to
    // squeeze carbs to zero. Such users get per-kg targets from their goal
    // weight instead (or, without one, the weight at BMI 25 for their height),
    // never below the weight at BMI 18.5.
    static let highBMIThreshold: Double = 30
    static let referenceBMI: Double = 25
    static let lowestReferenceBMI: Double = 18.5

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
        /// Weight the per-kg protein and fat figures use: the body weight,
        /// or for a BMI of 30+ the goal (or reference) weight.
        var proteinWeightKg: Double
        var ranges: NutritionTargetRanges
    }

    // MARK: Safeguards

    static func calorieFloor(for sex: BiologicalSex) -> Double {
        sex == .male ? NutritionConstants.minimumCalorieFloorMale
                     : NutritionConstants.minimumCalorieFloor
    }

    /// The weight per-kg protein and fat targets are based on. Body weight
    /// below a BMI of 30; above it, the goal weight if one lower than now is
    /// set, otherwise the weight at BMI 25 - never below the BMI 18.5 weight.
    static func proteinReferenceWeight(weightKg: Double, heightCm: Double,
                                       targetWeightKg: Double?) -> Double {
        let heightM = heightCm / 100
        guard heightM > 0, weightKg > 0 else { return weightKg }
        let bmi = weightKg / (heightM * heightM)
        guard bmi >= NutritionConstants.highBMIThreshold else { return weightKg }
        let fallback = NutritionConstants.referenceBMI * heightM * heightM
        let goal = targetWeightKg.flatMap { $0 > 0 && $0 < weightKg ? $0 : nil } ?? fallback
        let lowest = NutritionConstants.lowestReferenceBMI * heightM * heightM
        return min(weightKg, max(goal, lowest))
    }

    /// Keeps the calorie range on the right side of maintenance for the goal,
    /// then applies the floor, which wins over everything else.
    static func adjustedCalorieRange(_ range: NutrientRange, goal: FitnessGoal,
                                     tdee: Double, sex: BiologicalSex) -> NutrientRange {
        var low = range.min
        var high = range.max
        switch goal {
        case .loseWeight, .recomposition:
            high = min(high, (tdee * NutritionConstants.deficitCeilingFraction).rounded())
        case .buildMuscle:
            low = max(low, (tdee * NutritionConstants.surplusFloorFraction).rounded())
        case .maintain:
            break
        }
        let floor = calorieFloor(for: sex)
        low = max(low, floor)
        high = max(high, low)
        return NutrientRange(min: low, max: high)
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
                  activity: profile.activity,
                  targetWeightKg: profile.targetWeightKg)
    }

    static func calculate(weightKg: Double,
                          heightCm: Double,
                          age: Int,
                          sex: BiologicalSex,
                          goal: FitnessGoal,
                          activity: ActivityLevel,
                          targetWeightKg: Double? = nil) -> Breakdown {

        let safeWeight = max(1, weightKg)
        let bmr = basalMetabolicRate(weightKg: safeWeight, heightCm: max(1, heightCm),
                                     age: max(1, age), sex: sex)
        let tdee = totalDailyEnergyExpenditure(bmr: bmr, activity: activity)
        let multiplier = goalMultiplier(for: goal)
        let caloriePoint = max(calorieFloor(for: sex), (tdee * multiplier).rounded())

        // --- Calories: band around the point estimate, kept on the goal's
        //     side of maintenance and never below the floor.
        let calorieRange = adjustedCalorieRange(
            NutrientRange.band(around: caloriePoint,
                               fraction: NutritionConstants.calorieBandFraction),
            goal: goal, tdee: tdee, sex: sex)

        // --- Protein: the guideline is already a range, so use it directly
        //     instead of collapsing to a midpoint. Per kg of the reference
        //     weight, which differs from body weight only at a BMI of 30+.
        let proteinWeight = proteinReferenceWeight(weightKg: safeWeight,
                                                   heightCm: max(1, heightCm),
                                                   targetWeightKg: targetWeightKg)
        let proteinPerKg = proteinGramsPerKg(for: goal)
        let proteinRange = NutrientRange(min: (proteinWeight * proteinPerKg.min).rounded(),
                                         max: (proteinWeight * proteinPerKg.max).rounded())

        // --- Fat: the larger of a per-kg floor and a share of energy, banded.
        let fatFromWeight = proteinWeight * NutritionConstants.fatMinimumGramsPerKg
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
                         proteinWeightKg: proteinWeight,
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
