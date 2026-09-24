import Foundation
import SwiftData

struct IngredientBackup: Codable, Equatable {
    var id: UUID; var name: String; var quantity: Double; var servingSize: Double
    var unit: ServingUnit; var nutrition: Nutrition; var confidence: Double?; var canonicalID: String?
    init(_ item: IngredientItem) {
        id = item.id; name = item.name; quantity = item.quantity; servingSize = item.servingSize
        unit = item.unit; nutrition = item.nutrition; confidence = item.confidence; canonicalID = item.canonicalID
    }
    func model() -> IngredientItem { IngredientItem(id: id, name: name, quantity: quantity, servingSize: servingSize,
                                                      unit: unit, nutrition: nutrition, confidence: confidence, canonicalID: canonicalID) }
}
struct FoodBackup: Codable, Equatable {
    var id: UUID; var name: String; var consumedAt: Date; var quantity: Double; var servingSize: Double
    var unit: ServingUnit; var nutrition: Nutrition; var ingredients: [IngredientBackup]
    var source: FoodSource; var barcode: String?; var createdAt: Date; var updatedAt: Date
    init(_ entry: FoodEntry) {
        id = entry.id; name = entry.name; consumedAt = entry.consumedAt; quantity = entry.quantity
        servingSize = entry.servingSize; unit = entry.unit; nutrition = entry.nutrition
        ingredients = entry.ingredients.map(IngredientBackup.init); source = entry.source
        barcode = entry.barcode; createdAt = entry.createdAt; updatedAt = entry.updatedAt
    }
    func model() -> FoodEntry {
        let result = FoodEntry(id: id, name: name, consumedAt: consumedAt, quantity: quantity,
                               servingSize: servingSize, unit: unit, nutrition: nutrition,
                               ingredients: ingredients.map { $0.model() }, source: source, barcode: barcode)
        result.createdAt = createdAt; result.updatedAt = updatedAt
        return result
    }
}
struct ProfileBackup: Codable {
    var dateOfBirth: Date; var sex: BiologicalSex; var heightCm: Double; var weightKg: Double
    var targetWeightKg: Double?; var goal: FitnessGoal; var activity: ActivityLevel
    var strengthSessions: Int; var cardioSessions: Int; var bodyFatPercent: Double?
    init(_ p: UserProfile) {
        dateOfBirth = p.dateOfBirth; sex = p.sex; heightCm = p.heightCm; weightKg = p.weightKg
        targetWeightKg = p.targetWeightKg; goal = p.goal; activity = p.activity
        strengthSessions = p.strengthSessions; cardioSessions = p.cardioSessions; bodyFatPercent = p.bodyFatPercent
    }
    func model() -> UserProfile {
        UserProfile(dateOfBirth: dateOfBirth, sex: sex, heightCm: heightCm, weightKg: weightKg,
                    targetWeightKg: targetWeightKg, goal: goal, activity: activity,
                    strengthSessions: strengthSessions, cardioSessions: cardioSessions,
                    bodyFatPercent: bodyFatPercent)
    }
}
struct TargetBackup: Codable {
    var nutrition: Nutrition; var manuallyModified: Bool
    init(_ target: NutritionTarget) { nutrition = target.nutrition; manuallyModified = target.manuallyModified }
    func model() -> NutritionTarget { NutritionTarget(nutrition, manuallyModified: manuallyModified) }
}
struct BarcodeBackup: Codable {
    var barcode: String; var name: String; var brand: String?; var servingSize: Double
    var unit: ServingUnit; var nutrition: Nutrition
    init(_ c: BarcodeProductCache) {
        barcode = c.barcode; name = c.name; brand = c.brand; servingSize = c.servingSize
        unit = ServingUnit(rawValue: c.unitRaw) ?? .gram; nutrition = c.nutrition
    }
    func model() -> BarcodeProductCache {
        BarcodeProductCache(barcode: barcode, name: name, brand: brand, servingSize: servingSize,
                            unit: unit, nutrition: nutrition)
    }
}
struct NutritionBackup: Codable {
    var schemaVersion = 2
    var exportDate = Date()
    var profile: ProfileBackup?
    var target: TargetBackup?
    var foodEntries: [FoodBackup]
    var barcodeCache: [BarcodeBackup]
    func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw BackupError.unsupportedVersion }
        guard foodEntries.allSatisfy({ $0.quantity > 0 && $0.servingSize > 0 && $0.nutrition.isValid &&
            $0.ingredients.allSatisfy { $0.quantity > 0 && $0.servingSize > 0 && $0.nutrition.isValid } }) else {
            throw BackupError.invalidData
        }
        guard target?.nutrition.isValid ?? true else { throw BackupError.invalidData }
    }
}
enum BackupError: LocalizedError {
    case unsupportedVersion, invalidData
    var errorDescription: String? { self == .unsupportedVersion ? "Unsupported backup version." : "Backup contains invalid nutrition data." }
}
enum BackupService {
    static func encode(_ backup: NutritionBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Version 1 used ISO 8601 without fractional seconds. Version 2 preserves Date precision.
        encoder.dateEncodingStrategy = backup.schemaVersion == 1 ? .iso8601 : .deferredToDate
        return try encoder.encode(backup)
    }
    static func decode(_ data: Data) throws -> NutritionBackup {
        let version = try JSONDecoder().decode(BackupVersion.self, from: data).schemaVersion
        guard version == 1 || version == 2 else { throw BackupError.unsupportedVersion }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = version == 1 ? .iso8601 : .deferredToDate
        let backup = try decoder.decode(NutritionBackup.self, from: data)
        try backup.validate(); return backup
    }
}

private struct BackupVersion: Decodable { let schemaVersion: Int }
