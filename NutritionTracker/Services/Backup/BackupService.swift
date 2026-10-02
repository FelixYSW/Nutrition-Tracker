import Foundation
import SwiftData

// MARK: - Export DTOs

/// Versioned backup envelope (spec section 30).
///
/// `schemaVersion` is checked *before* decoding the payload, so a future backup
/// produces a clear message instead of a confusing decode failure.
struct BackupFile: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportDate: Date
    var appVersion: String?
    var profile: ProfileDTO?
    var target: TargetDTO?
    var foodEntries: [FoodEntryDTO]
    var barcodeCache: [BarcodeCacheDTO]

    init(schemaVersion: Int = BackupFile.currentSchemaVersion,
         exportDate: Date = .now,
         appVersion: String? = nil,
         profile: ProfileDTO? = nil,
         target: TargetDTO? = nil,
         foodEntries: [FoodEntryDTO] = [],
         barcodeCache: [BarcodeCacheDTO] = []) {
        self.schemaVersion = schemaVersion
        self.exportDate = exportDate
        self.appVersion = appVersion
        self.profile = profile
        self.target = target
        self.foodEntries = foodEntries
        self.barcodeCache = barcodeCache
    }
}

struct ProfileDTO: Codable, Equatable {
    var dateOfBirth: Date
    var sex: String
    var heightCm: Double
    var weightKg: Double
    var targetWeightKg: Double?
    var goal: String
    var activity: String
    var strengthSessionsPerWeek: Int
    var cardioSessionsPerWeek: Int
    var bodyFatPercent: Double?
}

/// Targets export as bands, matching the v2 model.
struct TargetDTO: Codable, Equatable {
    var calories: NutrientRange
    var protein: NutrientRange
    var carbs: NutrientRange
    var fat: NutrientRange
    var fibre: NutrientRange
}

struct FoodEntryDTO: Codable, Equatable {
    var id: UUID
    var name: String
    var consumedAt: Date
    var quantity: Double
    var servingSize: Double
    var unit: String
    var nutritionPerServing: Nutrition
    var ingredients: [IngredientDTO]
    var source: String
    var photoPath: String?
    var barcode: String?
    var createdAt: Date
    var updatedAt: Date
}

struct IngredientDTO: Codable, Equatable {
    var id: UUID
    var name: String
    var quantity: Double
    var servingSize: Double
    var unit: String
    var nutritionPerServing: Nutrition
    var confidence: Double?
    var canonicalID: String?
}

struct BarcodeCacheDTO: Codable, Equatable {
    var barcode: String
    var name: String
    var brand: String?
    var servingSize: Double
    var unit: String
    var nutritionPerServing: Nutrition
    var isUserEntered: Bool
    var fetchedAt: Date
}

// MARK: - Errors

enum BackupError: LocalizedError, Equatable {
    case unreadableFile
    case notABackup
    case unsupportedVersion(found: Int, supported: Int)
    case corruptPayload(detail: String)
    case writeFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "That file could not be read."
        case .notABackup:
            "That file is not a Nutrition Tracker backup."
        case .unsupportedVersion(let found, let supported):
            "This backup was written by a newer version of the app "
                + "(backup format \(found), this build understands \(supported)). "
                + "Update the app and try again."
        case .corruptPayload(let detail):
            "The backup is incomplete or damaged: \(detail)"
        case .writeFailed(let detail):
            "The backup could not be written: \(detail)"
        }
    }
}

// MARK: - Service

/// Export/import of the whole local database as versioned JSON.
///
/// Import validates everything *before* touching the live database, so a bad
/// file cannot leave the store half-written (spec section 30).
@MainActor
struct BackupService {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Export

    func makeBackup() -> BackupFile {
        let profile = context.loadUserProfile()
        let target = context.loadNutritionTarget()

        let entries = (try? context.fetch(FetchDescriptor<FoodEntry>(
            sortBy: [SortDescriptor(\.consumedAt, order: .forward)]))) ?? []
        let cache = (try? context.fetch(FetchDescriptor<BarcodeProductCache>())) ?? []

        return BackupFile(
            exportDate: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            profile: profile.map {
                ProfileDTO(dateOfBirth: $0.dateOfBirth,
                           sex: $0.sexRaw,
                           heightCm: $0.heightCm,
                           weightKg: $0.weightKg,
                           targetWeightKg: $0.targetWeightKg,
                           goal: $0.goalRaw,
                           activity: $0.activityRaw,
                           strengthSessionsPerWeek: $0.strengthSessionsPerWeek,
                           cardioSessionsPerWeek: $0.cardioSessionsPerWeek,
                           bodyFatPercent: $0.bodyFatPercent)
            },
            target: target.map {
                TargetDTO(calories: $0.calories, protein: $0.protein,
                          carbs: $0.carbs, fat: $0.fat, fibre: $0.fibre)
            },
            foodEntries: entries.map { entry in
                FoodEntryDTO(id: entry.id,
                             name: entry.name,
                             consumedAt: entry.consumedAt,
                             quantity: entry.quantity,
                             servingSize: entry.servingSize,
                             unit: entry.unitRaw,
                             nutritionPerServing: entry.nutritionPerServing,
                             ingredients: entry.orderedIngredients.map { item in
                                 IngredientDTO(id: item.id,
                                               name: item.name,
                                               quantity: item.quantity,
                                               servingSize: item.servingSize,
                                               unit: item.unitRaw,
                                               nutritionPerServing: item.nutritionPerServing,
                                               confidence: item.confidence,
                                               canonicalID: item.canonicalID)
                             },
                             source: entry.sourceRaw,
                             photoPath: entry.photoPath,
                             barcode: entry.barcode,
                             createdAt: entry.createdAt,
                             updatedAt: entry.updatedAt)
            },
            barcodeCache: cache.map {
                BarcodeCacheDTO(barcode: $0.barcode,
                                name: $0.name,
                                brand: $0.brand,
                                servingSize: $0.servingSize,
                                unit: $0.unitRaw,
                                nutritionPerServing: $0.nutritionPerServing,
                                isUserEntered: $0.isUserEntered,
                                fetchedAt: $0.fetchedAt)
            })
    }

    func exportData() throws -> Data {
        do {
            return try Self.makeEncoder().encode(makeBackup())
        } catch {
            throw BackupError.writeFailed(detail: error.localizedDescription)
        }
    }

    /// Writes the backup to a temporary file for the share sheet / document picker.
    func exportToTemporaryFile() throws -> URL {
        let data = try exportData()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "NutritionTracker-backup-\(formatter.string(from: .now)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BackupError.writeFailed(detail: error.localizedDescription)
        }
        return url
    }

    // MARK: Import

    /// Parses and validates without writing anything. Always call this first.
    static func validate(data: Data) throws -> BackupFile {
        // Read the version on its own before decoding the body, so a newer
        // backup gives a version message rather than a decode error.
        struct VersionProbe: Decodable { let schemaVersion: Int? }

        let probe: VersionProbe
        do {
            probe = try makeDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw BackupError.notABackup
        }

        guard let version = probe.schemaVersion else {
            throw BackupError.notABackup
        }
        guard version <= BackupFile.currentSchemaVersion else {
            throw BackupError.unsupportedVersion(found: version,
                                                 supported: BackupFile.currentSchemaVersion)
        }

        let file: BackupFile
        do {
            file = try makeDecoder().decode(BackupFile.self, from: data)
        } catch let error as DecodingError {
            throw BackupError.corruptPayload(detail: Self.describe(error))
        } catch {
            throw BackupError.corruptPayload(detail: error.localizedDescription)
        }

        try validateContents(file)
        return file
    }

    /// Semantic checks beyond "it decoded": no NaN nutrition, no negative
    /// quantities, no unknown enum values.
    static func validateContents(_ file: BackupFile) throws {
        if let profile = file.profile {
            guard BiologicalSex(rawValue: profile.sex) != nil else {
                throw BackupError.corruptPayload(detail: "unknown sex \"\(profile.sex)\"")
            }
            guard FitnessGoal(rawValue: profile.goal) != nil else {
                throw BackupError.corruptPayload(detail: "unknown goal \"\(profile.goal)\"")
            }
            guard ActivityLevel(rawValue: profile.activity) != nil else {
                throw BackupError.corruptPayload(detail: "unknown activity \"\(profile.activity)\"")
            }
            guard profile.heightCm > 0, profile.weightKg > 0 else {
                throw BackupError.corruptPayload(detail: "height and weight must be positive")
            }
        }

        for entry in file.foodEntries {
            guard ServingUnit(rawValue: entry.unit) != nil else {
                throw BackupError.corruptPayload(detail: "unknown unit \"\(entry.unit)\"")
            }
            guard FoodSource(rawValue: entry.source) != nil else {
                throw BackupError.corruptPayload(detail: "unknown source \"\(entry.source)\"")
            }
            guard entry.quantity >= 0, entry.servingSize > 0 else {
                throw BackupError.corruptPayload(
                    detail: "invalid quantity on \"\(entry.name)\"")
            }
            guard entry.nutritionPerServing.isValid else {
                throw BackupError.corruptPayload(
                    detail: "invalid nutrition on \"\(entry.name)\"")
            }
            for ingredient in entry.ingredients {
                guard ServingUnit(rawValue: ingredient.unit) != nil else {
                    throw BackupError.corruptPayload(
                        detail: "unknown unit \"\(ingredient.unit)\"")
                }
                guard ingredient.quantity >= 0, ingredient.servingSize > 0,
                      ingredient.nutritionPerServing.isValid else {
                    throw BackupError.corruptPayload(
                        detail: "invalid ingredient \"\(ingredient.name)\"")
                }
            }
        }

        for product in file.barcodeCache {
            guard ServingUnit(rawValue: product.unit) != nil else {
                throw BackupError.corruptPayload(detail: "unknown unit \"\(product.unit)\"")
            }
            guard product.nutritionPerServing.isValid else {
                throw BackupError.corruptPayload(
                    detail: "invalid nutrition for barcode \(product.barcode)")
            }
        }
    }

    enum ImportStrategy {
        /// Deletes existing data first. What "restore a backup" means.
        case replace
        /// Keeps existing data, adding entries whose id is not already present.
        case merge
    }

    struct ImportSummary: Equatable {
        var entriesImported: Int
        var entriesSkipped: Int
        var productsImported: Int
        var replacedProfile: Bool
    }

    /// Applies an already-validated backup.
    @discardableResult
    func importBackup(_ file: BackupFile, strategy: ImportStrategy) throws -> ImportSummary {
        // Validated again defensively: this method is callable directly, and the
        // cost of re-checking is trivial next to a corrupted store.
        try Self.validateContents(file)

        var summary = ImportSummary(entriesImported: 0, entriesSkipped: 0,
                                    productsImported: 0, replacedProfile: false)

        if strategy == .replace {
            deleteAllData(includingImages: false)
        }

        // Profile
        if let dto = file.profile,
           let sex = BiologicalSex(rawValue: dto.sex),
           let goal = FitnessGoal(rawValue: dto.goal),
           let activity = ActivityLevel(rawValue: dto.activity) {
            if let existing = context.loadUserProfile(), strategy == .merge {
                existing.dateOfBirth = dto.dateOfBirth
                existing.sex = sex
                existing.heightCm = dto.heightCm
                existing.weightKg = dto.weightKg
                existing.targetWeightKg = dto.targetWeightKg
                existing.goal = goal
                existing.activity = activity
                existing.strengthSessionsPerWeek = dto.strengthSessionsPerWeek
                existing.cardioSessionsPerWeek = dto.cardioSessionsPerWeek
                existing.bodyFatPercent = dto.bodyFatPercent
            } else {
                context.insert(UserProfile(
                    dateOfBirth: dto.dateOfBirth, sex: sex,
                    heightCm: dto.heightCm, weightKg: dto.weightKg,
                    targetWeightKg: dto.targetWeightKg, goal: goal, activity: activity,
                    strengthSessionsPerWeek: dto.strengthSessionsPerWeek,
                    cardioSessionsPerWeek: dto.cardioSessionsPerWeek,
                    bodyFatPercent: dto.bodyFatPercent))
            }
            summary.replacedProfile = true
        }

        // Targets
        if let dto = file.target {
            let ranges = NutritionTargetRanges(calories: dto.calories, protein: dto.protein,
                                               carbs: dto.carbs, fat: dto.fat, fibre: dto.fibre)
            if let existing = context.loadNutritionTarget() {
                existing.ranges = ranges
            } else {
                context.insert(NutritionTarget(ranges: ranges))
            }
        }

        // Entries
        for dto in file.foodEntries {
            if strategy == .merge, context.fetchEntry(id: dto.id) != nil {
                summary.entriesSkipped += 1
                continue
            }
            guard let unit = ServingUnit(rawValue: dto.unit),
                  let source = FoodSource(rawValue: dto.source) else {
                summary.entriesSkipped += 1
                continue
            }
            // Array order in the backup is the display order (export writes
            // `orderedIngredients`), so it becomes `position` on restore.
            let ingredients = dto.ingredients.enumerated().compactMap { index, item -> IngredientItem? in
                guard let itemUnit = ServingUnit(rawValue: item.unit) else { return nil }
                let restored = IngredientItem(id: item.id, name: item.name,
                                              quantity: item.quantity,
                                              servingSize: item.servingSize,
                                              unit: itemUnit,
                                              nutritionPerServing: item.nutritionPerServing,
                                              confidence: item.confidence,
                                              canonicalID: item.canonicalID)
                restored.position = index
                return restored
            }
            let entry = FoodEntry(id: dto.id, name: dto.name, consumedAt: dto.consumedAt,
                                  quantity: dto.quantity, servingSize: dto.servingSize,
                                  unit: unit, nutritionPerServing: dto.nutritionPerServing,
                                  ingredients: ingredients, source: source,
                                  // Photos are not inside the JSON, so a restored
                                  // entry keeps its reference but the image may
                                  // legitimately be gone.
                                  photoPath: dto.photoPath, barcode: dto.barcode)
            context.insert(entry)
            summary.entriesImported += 1
        }

        // Barcode cache
        for dto in file.barcodeCache {
            guard let unit = ServingUnit(rawValue: dto.unit) else { continue }
            if context.fetchCachedProduct(barcode: dto.barcode) != nil, strategy == .merge {
                continue
            }
            context.insert(BarcodeProductCache(
                barcode: dto.barcode, name: dto.name, brand: dto.brand,
                servingSize: dto.servingSize, unit: unit,
                nutritionPerServing: dto.nutritionPerServing,
                isUserEntered: dto.isUserEntered))
            summary.productsImported += 1
        }

        do {
            try context.save()
        } catch {
            throw BackupError.corruptPayload(detail: error.localizedDescription)
        }

        return summary
    }

    // MARK: Destructive

    /// Deletes everything the user created. Settings and Keychain secrets are
    /// handled separately by the caller.
    func deleteAllData(includingImages: Bool) {
        try? context.delete(model: FoodEntry.self)
        try? context.delete(model: IngredientItem.self)
        try? context.delete(model: BarcodeProductCache.self)
        try? context.delete(model: CorrectionRecord.self)
        try? context.delete(model: UserProfile.self)
        try? context.delete(model: NutritionTarget.self)
        if includingImages {
            ImageStore.deleteAll()
        }
        try? context.save()
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            "missing field \"\(key.stringValue)\""
        case .typeMismatch(_, let ctx):
            "wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(_, let ctx):
            "missing value at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let ctx):
            ctx.debugDescription
        @unknown default:
            "unreadable structure"
        }
    }
}
