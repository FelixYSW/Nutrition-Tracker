import Foundation
import SwiftData

// MARK: - UserProfile

@Model
final class UserProfile {
    var dateOfBirth: Date
    var sexRaw: String
    var heightCm: Double
    var weightKg: Double
    var targetWeightKg: Double?
    var goalRaw: String
    var activityRaw: String
    /// Stored for profile context only. Never re-added as calories, because the
    /// activity multiplier already accounts for exercise (spec section 6).
    var strengthSessionsPerWeek: Int
    var cardioSessionsPerWeek: Int
    var bodyFatPercent: Double?
    var createdAt: Date
    var updatedAt: Date

    /// Snapshot of the inputs used the last time targets were calculated, so the
    /// app can detect a significant profile change and *offer* a recalculation
    /// rather than silently recalculating (spec section 6).
    var targetsBasedOnWeightKg: Double?
    var targetsBasedOnGoalRaw: String?
    var targetsBasedOnActivityRaw: String?

    init(dateOfBirth: Date,
         sex: BiologicalSex,
         heightCm: Double,
         weightKg: Double,
         targetWeightKg: Double? = nil,
         goal: FitnessGoal,
         activity: ActivityLevel,
         strengthSessionsPerWeek: Int = 0,
         cardioSessionsPerWeek: Int = 0,
         bodyFatPercent: Double? = nil) {
        self.dateOfBirth = dateOfBirth
        self.sexRaw = sex.rawValue
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.targetWeightKg = targetWeightKg
        self.goalRaw = goal.rawValue
        self.activityRaw = activity.rawValue
        self.strengthSessionsPerWeek = strengthSessionsPerWeek
        self.cardioSessionsPerWeek = cardioSessionsPerWeek
        self.bodyFatPercent = bodyFatPercent
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sex: BiologicalSex {
        get { BiologicalSex(rawValue: sexRaw) ?? .female }
        set { sexRaw = newValue.rawValue; updatedAt = .now }
    }

    var goal: FitnessGoal {
        get { FitnessGoal(rawValue: goalRaw) ?? .maintain }
        set { goalRaw = newValue.rawValue; updatedAt = .now }
    }

    var activity: ActivityLevel {
        get { ActivityLevel(rawValue: activityRaw) ?? .sedentary }
        set { activityRaw = newValue.rawValue; updatedAt = .now }
    }

    func age(on date: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let years = calendar.dateComponents([.year], from: dateOfBirth, to: date).year ?? 0
        return max(1, years)
    }

    func markTargetsCalculated() {
        targetsBasedOnWeightKg = weightKg
        targetsBasedOnGoalRaw = goalRaw
        targetsBasedOnActivityRaw = activityRaw
        updatedAt = .now
    }

    /// True when the profile has drifted enough from the snapshot that the stored
    /// targets are probably stale. Weight threshold is deliberately generous so
    /// day-to-day fluctuation does not nag the user.
    var targetsLikelyStale: Bool {
        guard let basedOnWeight = targetsBasedOnWeightKg else { return false }
        if goalRaw != targetsBasedOnGoalRaw { return true }
        if activityRaw != targetsBasedOnActivityRaw { return true }
        return abs(weightKg - basedOnWeight) >= NutritionConstants.weightChangeRecalcThresholdKg
    }
}

// MARK: - NutritionTarget

/// Daily targets, stored as a `(min, max)` band per nutrient (spec section 9).
///
/// The bands are persisted as `NutrientRange` Codable values. They are never
/// used in a SwiftData `#Predicate`, so storing them as composite values is safe.
@Model
final class NutritionTarget {
    var calories: NutrientRange
    var protein: NutrientRange
    var carbs: NutrientRange
    var fat: NutrientRange
    var fibre: NutrientRange
    var createdAt: Date
    var updatedAt: Date

    init(ranges: NutritionTargetRanges) {
        self.calories = ranges.calories
        self.protein = ranges.protein
        self.carbs = ranges.carbs
        self.fat = ranges.fat
        self.fibre = ranges.fibre
        self.createdAt = .now
        self.updatedAt = .now
    }

    var ranges: NutritionTargetRanges {
        get {
            NutritionTargetRanges(calories: calories, protein: protein,
                                  carbs: carbs, fat: fat, fibre: fibre)
        }
        set {
            calories = newValue.calories
            protein = newValue.protein
            carbs = newValue.carbs
            fat = newValue.fat
            fibre = newValue.fibre
            updatedAt = .now
        }
    }

    /// Replaces the calculated bands while preserving any bound the user edited
    /// by hand, so a recalculation never silently discards a manual override.
    func apply(recalculated: NutritionTargetRanges) {
        var merged = recalculated
        let existing = ranges
        for nutrient in Nutrient.allCases {
            var range = merged[nutrient]
            let old = existing[nutrient]
            if old.minManuallyModified {
                range = range.withManualMin(old.min)
            }
            if old.maxManuallyModified {
                range = range.withManualMax(old.max)
            }
            merged[nutrient] = range
        }
        ranges = merged
    }
}

// MARK: - IngredientItem

@Model
final class IngredientItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var quantity: Double
    var servingSize: Double
    var unitRaw: String
    /// Nutrition *per serving size*, not per quantity.
    var nutritionPerServing: Nutrition
    /// Model A / Model B confidence where this came from the photo pipeline.
    var confidence: Double?
    /// Canonical ontology identifier, used to resolve against MyFCD and the
    /// rest of the nutrition data layer (spec sections 22 and 23).
    var canonicalID: String?
    var createdAt: Date
    /// Display order within the parent. SwiftData does not preserve the order
    /// of a to-many relationship, so it is stored explicitly.
    var position: Int = 0

    init(id: UUID = UUID(),
         name: String,
         quantity: Double = 1,
         servingSize: Double = 1,
         unit: ServingUnit = .serving,
         nutritionPerServing: Nutrition = .zero,
         confidence: Double? = nil,
         canonicalID: String? = nil) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.servingSize = servingSize
        self.unitRaw = unit.rawValue
        self.nutritionPerServing = nutritionPerServing
        self.confidence = confidence
        self.canonicalID = canonicalID
        self.createdAt = .now
    }

    var unit: ServingUnit {
        get { ServingUnit(rawValue: unitRaw) ?? .serving }
        set { unitRaw = newValue.rawValue }
    }

    /// Nutrition scaled to the logged quantity. Derived, never stored, so there
    /// is no redundant total to keep in sync (spec section 9).
    var total: Nutrition {
        nutritionPerServing * NutritionMath.scaleFactor(quantity: quantity, servingSize: servingSize)
    }

    /// Flagged in the review UI so the user knows what to check first.
    var isLowConfidence: Bool {
        guard let confidence else { return false }
        return confidence < NutritionConstants.lowConfidenceThreshold
    }
}

// MARK: - FoodEntry

@Model
final class FoodEntry {
    @Attribute(.unique) var id: UUID
    var name: String
    var consumedAt: Date
    var quantity: Double
    var servingSize: Double
    var unitRaw: String
    /// Used only for a *simple* food. For a composite food the parent nutrition
    /// is derived from the children (spec section 10).
    var nutritionPerServing: Nutrition
    @Relationship(deleteRule: .cascade) var ingredients: [IngredientItem]
    var sourceRaw: String
    /// Relative path inside the images directory, not an absolute path.
    var photoPath: String?
    var barcode: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         consumedAt: Date = .now,
         quantity: Double = 1,
         servingSize: Double = 1,
         unit: ServingUnit = .serving,
         nutritionPerServing: Nutrition = .zero,
         ingredients: [IngredientItem] = [],
         source: FoodSource = .manual,
         photoPath: String? = nil,
         barcode: String? = nil) {
        self.id = id
        self.name = name
        self.consumedAt = consumedAt
        self.quantity = quantity
        self.servingSize = servingSize
        self.unitRaw = unit.rawValue
        self.nutritionPerServing = nutritionPerServing
        self.ingredients = ingredients
        self.sourceRaw = source.rawValue
        self.photoPath = photoPath
        self.barcode = barcode
        self.createdAt = .now
        self.updatedAt = .now
    }

    var unit: ServingUnit {
        get { ServingUnit(rawValue: unitRaw) ?? .serving }
        set { unitRaw = newValue.rawValue; updatedAt = .now }
    }

    var source: FoodSource {
        get { FoodSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue; updatedAt = .now }
    }

    var isComposite: Bool { !ingredients.isEmpty }

    /// Ingredients in the order the user arranged them.
    var orderedIngredients: [IngredientItem] {
        ingredients.sorted { $0.position < $1.position }
    }

    /// Nutrition for one serving of this entry: either its own figures, or the
    /// sum of its ingredients when it is composite.
    var nutritionForOneServing: Nutrition {
        isComposite ? ingredients.reduce(.zero) { $0 + $1.total } : nutritionPerServing
    }

    /// Nutrition actually consumed, scaled by the parent quantity. Scaling the
    /// parent therefore scales a composite food's whole ingredient list.
    var total: Nutrition {
        nutritionForOneServing * NutritionMath.scaleFactor(quantity: quantity, servingSize: servingSize)
    }

    func touch() { updatedAt = .now }
}

// MARK: - BarcodeProductCache

@Model
final class BarcodeProductCache {
    @Attribute(.unique) var barcode: String
    var name: String
    var brand: String?
    var servingSize: Double
    var unitRaw: String
    var nutritionPerServing: Nutrition
    /// True when the user typed this in after a "Product Not Found", so it is
    /// treated as locally verified and ranked first on lookup (spec section 23).
    var isUserEntered: Bool
    var fetchedAt: Date

    init(barcode: String,
         name: String,
         brand: String? = nil,
         servingSize: Double = 100,
         unit: ServingUnit = .gram,
         nutritionPerServing: Nutrition,
         isUserEntered: Bool = false) {
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.servingSize = servingSize
        self.unitRaw = unit.rawValue
        self.nutritionPerServing = nutritionPerServing
        self.isUserEntered = isUserEntered
        self.fetchedAt = .now
    }

    var unit: ServingUnit {
        get { ServingUnit(rawValue: unitRaw) ?? .gram }
        set { unitRaw = newValue.rawValue }
    }
}

// MARK: - CorrectionRecord

/// A locally retained record of what the models predicted versus what the user
/// confirmed (spec section 24).
///
/// This is the only route by which local-dish recognition improves, given how
/// thin the public Malaysian datasets are. It never leaves the device unless an
/// explicit export action is added later.
@Model
final class CorrectionRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// JSON-encoded `PhotoAnalysisResult` as the pipeline produced it.
    var predictionJSON: Data
    /// JSON-encoded draft as the user confirmed it.
    var correctionJSON: Data
    var photoPath: String?

    init(predictionJSON: Data, correctionJSON: Data, photoPath: String? = nil) {
        self.id = UUID()
        self.createdAt = .now
        self.predictionJSON = predictionJSON
        self.correctionJSON = correctionJSON
        self.photoPath = photoPath
    }
}

// MARK: - AppSettings

/// Small single-row settings record. Lives in SwiftData rather than UserDefaults
/// so it travels with export/import. Never holds secrets - those go to the
/// Keychain (spec sections 26 and 39).
@Model
final class AppSettings {
    @Attribute(.unique) var id: String
    var retainAnalysedImages: Bool
    var storeCorrectionsForTraining: Bool
    /// Explicit opt-in required before the assistant sends any personal
    /// nutrition data to a third-party LLM (spec section 29A).
    var assistantDataSharingOptIn: Bool
    var assistantProviderRaw: String
    var remoteVisionFallbackEnabled: Bool
    var hasCompletedOnboarding: Bool

    init(id: String = AppSettings.singletonID,
         retainAnalysedImages: Bool = true,
         storeCorrectionsForTraining: Bool = false,
         assistantDataSharingOptIn: Bool = false,
         assistantProvider: AssistantProvider = .anthropic,
         remoteVisionFallbackEnabled: Bool = false,
         hasCompletedOnboarding: Bool = false) {
        self.id = id
        self.retainAnalysedImages = retainAnalysedImages
        self.storeCorrectionsForTraining = storeCorrectionsForTraining
        self.assistantDataSharingOptIn = assistantDataSharingOptIn
        self.assistantProviderRaw = assistantProvider.rawValue
        self.remoteVisionFallbackEnabled = remoteVisionFallbackEnabled
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    static let singletonID = "app-settings"

    var assistantProvider: AssistantProvider {
        get { AssistantProvider(rawValue: assistantProviderRaw) ?? .anthropic }
        set { assistantProviderRaw = newValue.rawValue }
    }
}

// MARK: - Shared math

enum NutritionMath {
    /// Quantity-to-serving scale factor, guarded against a zero or invalid
    /// serving size so nutrition never becomes NaN or infinite.
    static func scaleFactor(quantity: Double, servingSize: Double) -> Double {
        guard quantity.isFinite, quantity >= 0 else { return 0 }
        guard servingSize.isFinite, servingSize > 0 else { return 0 }
        return quantity / servingSize
    }
}
