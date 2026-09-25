import Foundation
import SwiftData

enum FoodSource: String, Codable, CaseIterable { case manual, photoAI, barcode }
enum ServingUnit: String, Codable, CaseIterable, Identifiable {
    case serving, piece, gram, millilitre, scoop, tablespoon, teaspoon
    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .serving: "srv"
        case .piece: "pc"
        case .gram: "g"
        case .millilitre: "ml"
        case .scoop: "scoop"
        case .tablespoon: "tbsp"
        case .teaspoon: "tsp"
        }
    }
    var step: Double {
        switch self { case .piece: 1; case .gram: 10; case .millilitre: 25; case .scoop: 0.5; default: 0.25 }
    }
}
enum BiologicalSex: String, Codable, CaseIterable, Identifiable { case female, male; var id: String { rawValue } }
enum FitnessGoal: String, Codable, CaseIterable, Identifiable {
    case loseWeight, recomposition, maintain, buildMuscle
    var id: String { rawValue }
    var title: String { switch self { case .loseWeight: "Lose Weight"; case .recomposition: "Lose Fat + Build Muscle"; case .maintain: "Maintain"; case .buildMuscle: "Build Muscle" } }
}
enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary, light, moderate, active, veryActive
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var multiplier: Double { switch self { case .sedentary: 1.2; case .light: 1.375; case .moderate: 1.55; case .active: 1.725; case .veryActive: 1.9 } }
}

struct Nutrition: Codable, Equatable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fibre: Double = 0
    var sugar: Double = 0
    var sodium: Double = 0
    static let zero = Nutrition()
    static func + (a: Nutrition, b: Nutrition) -> Nutrition {
        Nutrition(calories: a.calories+b.calories, protein: a.protein+b.protein,
                  carbs: a.carbs+b.carbs, fat: a.fat+b.fat, fibre: a.fibre+b.fibre,
                  sugar: a.sugar+b.sugar, sodium: a.sodium+b.sodium)
    }
    static func * (a: Nutrition, factor: Double) -> Nutrition {
        Nutrition(calories: a.calories*factor, protein: a.protein*factor,
                  carbs: a.carbs*factor, fat: a.fat*factor, fibre: a.fibre*factor,
                  sugar: a.sugar*factor, sodium: a.sodium*factor)
    }
    var isValid: Bool {
        [calories, protein, carbs, fat, fibre, sugar, sodium].allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

@Model final class UserProfile {
    var dateOfBirth: Date
    var sexRaw: String
    var heightCm: Double
    var weightKg: Double
    var targetWeightKg: Double?
    var goalRaw: String
    var activityRaw: String
    var strengthSessions: Int
    var cardioSessions: Int
    var bodyFatPercent: Double?
    init(dateOfBirth: Date, sex: BiologicalSex, heightCm: Double, weightKg: Double,
         targetWeightKg: Double? = nil, goal: FitnessGoal, activity: ActivityLevel,
         strengthSessions: Int = 0, cardioSessions: Int = 0, bodyFatPercent: Double? = nil) {
        self.dateOfBirth = dateOfBirth; sexRaw = sex.rawValue; self.heightCm = heightCm
        self.weightKg = weightKg; self.targetWeightKg = targetWeightKg
        goalRaw = goal.rawValue; activityRaw = activity.rawValue
        self.strengthSessions = strengthSessions; self.cardioSessions = cardioSessions
        self.bodyFatPercent = bodyFatPercent
    }
    var sex: BiologicalSex { BiologicalSex(rawValue: sexRaw) ?? .female }
    var goal: FitnessGoal { FitnessGoal(rawValue: goalRaw) ?? .maintain }
    var activity: ActivityLevel { ActivityLevel(rawValue: activityRaw) ?? .sedentary }
}

@Model final class NutritionTarget {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fibre: Double
    var manuallyModified: Bool
    var updatedAt: Date
    init(_ n: Nutrition, manuallyModified: Bool = false) {
        calories = n.calories; protein = n.protein; carbs = n.carbs; fat = n.fat
        fibre = n.fibre; self.manuallyModified = manuallyModified; updatedAt = .now
    }
    var nutrition: Nutrition { Nutrition(calories: calories, protein: protein, carbs: carbs, fat: fat, fibre: fibre) }
    func update(_ n: Nutrition, manual: Bool) {
        calories = n.calories; protein = n.protein; carbs = n.carbs; fat = n.fat
        fibre = n.fibre; manuallyModified = manual; updatedAt = .now
    }
}

@Model final class IngredientItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var quantity: Double
    var servingSize: Double
    var unitRaw: String
    var nutritionData: Data
    var confidence: Double?
    var canonicalID: String?
    init(id: UUID = UUID(), name: String, quantity: Double = 1, servingSize: Double = 1,
         unit: ServingUnit = .serving, nutrition: Nutrition = .zero,
         confidence: Double? = nil, canonicalID: String? = nil) {
        self.id = id; self.name = name; self.quantity = quantity; self.servingSize = servingSize
        unitRaw = unit.rawValue; nutritionData = (try? JSONEncoder().encode(nutrition)) ?? Data()
        self.confidence = confidence; self.canonicalID = canonicalID
    }
    var unit: ServingUnit { ServingUnit(rawValue: unitRaw) ?? .serving }
    var nutrition: Nutrition {
        get { (try? JSONDecoder().decode(Nutrition.self, from: nutritionData)) ?? .zero }
        set { nutritionData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var total: Nutrition { nutrition * (quantity / max(servingSize, 0.0001)) }
}

@Model final class FoodEntry {
    @Attribute(.unique) var id: UUID
    var name: String
    var consumedAt: Date
    var quantity: Double
    var servingSize: Double
    var unitRaw: String
    var nutritionData: Data
    @Relationship(deleteRule: .cascade) var ingredients: [IngredientItem]
    var sourceRaw: String
    var photoPath: String?
    var barcode: String?
    var createdAt: Date
    var updatedAt: Date
    init(id: UUID = UUID(), name: String, consumedAt: Date = .now, quantity: Double = 1,
         servingSize: Double = 1, unit: ServingUnit = .serving, nutrition: Nutrition = .zero,
         ingredients: [IngredientItem] = [], source: FoodSource = .manual,
         photoPath: String? = nil, barcode: String? = nil) {
        self.id = id; self.name = name; self.consumedAt = consumedAt; self.quantity = quantity
        self.servingSize = servingSize; unitRaw = unit.rawValue
        nutritionData = (try? JSONEncoder().encode(nutrition)) ?? Data()
        self.ingredients = ingredients; sourceRaw = source.rawValue
        self.photoPath = photoPath; self.barcode = barcode; createdAt = .now; updatedAt = .now
    }
    var unit: ServingUnit { ServingUnit(rawValue: unitRaw) ?? .serving }
    var source: FoodSource { FoodSource(rawValue: sourceRaw) ?? .manual }
    var nutrition: Nutrition {
        get { (try? JSONDecoder().decode(Nutrition.self, from: nutritionData)) ?? .zero }
        set { nutritionData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }
    var total: Nutrition {
        let base = ingredients.isEmpty ? nutrition : ingredients.reduce(.zero) { $0 + $1.total }
        return base * (quantity / max(servingSize, 0.0001))
    }
}

@Model final class BarcodeProductCache {
    @Attribute(.unique) var barcode: String
    var name: String
    var brand: String?
    var servingSize: Double
    var unitRaw: String
    var nutritionData: Data
    var updatedAt: Date
    init(barcode: String, name: String, brand: String? = nil, servingSize: Double = 100,
         unit: ServingUnit = .gram, nutrition: Nutrition) {
        self.barcode = barcode; self.name = name; self.brand = brand
        self.servingSize = servingSize; unitRaw = unit.rawValue
        nutritionData = (try? JSONEncoder().encode(nutrition)) ?? Data(); updatedAt = .now
    }
    var nutrition: Nutrition { (try? JSONDecoder().decode(Nutrition.self, from: nutritionData)) ?? .zero }
}

@Model final class CorrectionRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var originalJSON: Data
    var correctedJSON: Data
    var photoPath: String?
    init(originalJSON: Data, correctedJSON: Data, photoPath: String? = nil) {
        id = UUID(); createdAt = .now; self.originalJSON = originalJSON
        self.correctedJSON = correctedJSON; self.photoPath = photoPath
    }
}
