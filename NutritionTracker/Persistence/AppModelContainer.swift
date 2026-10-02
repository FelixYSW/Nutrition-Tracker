import Foundation
import SwiftData

/// Owns the SwiftData stack.
///
/// The store lives in the normal app container. It is never deleted or recreated
/// on upgrade - a new build signed over the old install must find the same
/// database (spec section 31). Schema changes go through a versioned migration
/// plan rather than a wipe.
enum AppModelContainer {

    /// Every persisted type. Keep in sync with `AppSchemaV1`.
    static let models: [any PersistentModel.Type] = [
        UserProfile.self,
        NutritionTarget.self,
        FoodEntry.self,
        IngredientItem.self,
        BarcodeProductCache.self,
        CorrectionRecord.self,
        AppSettings.self
    ]

    static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration("NutritionTracker", schema: schema)
        do {
            return try ModelContainer(for: schema,
                                      migrationPlan: AppMigrationPlan.self,
                                      configurations: configuration)
        } catch {
            // Deliberately fatal: continuing with no database would silently
            // drop the user's food log. A crash here is loud and recoverable
            // from a backup, whereas a silent in-memory fallback is not.
            fatalError("Unable to open the nutrition database: \(error)")
        }
    }

    /// In-memory container for tests and SwiftUI previews.
    static func makeInMemoryContainer() -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Unable to create in-memory container: \(error)")
        }
    }
}

// MARK: - Migration

/// Versioned schema. V1 is the shipping schema; adding a V2 means appending a
/// `VersionedSchema` and a migration stage here, never resetting the store.
enum AppSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        AppModelContainer.models
    }
}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // No stages yet. When the schema changes, add a lightweight or custom
        // stage from AppSchemaV1 to AppSchemaV2 here.
        []
    }
}

// MARK: - Singleton accessors

extension ModelContext {

    /// Fetches the single settings row, creating it on first access.
    func loadAppSettings() -> AppSettings {
        let singletonID = AppSettings.singletonID
        let descriptor = FetchDescriptor<AppSettings>(
            predicate: #Predicate { $0.id == singletonID }
        )
        if let existing = try? fetch(descriptor).first {
            return existing
        }
        let created = AppSettings()
        insert(created)
        try? save()
        return created
    }

    func loadUserProfile() -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func loadNutritionTarget() -> NutritionTarget? {
        var descriptor = FetchDescriptor<NutritionTarget>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    /// Entries for one local calendar day, filtered in the store rather than in
    /// memory. The bounds are computed in Swift because `#Predicate` cannot call
    /// `Calendar` methods.
    func fetchEntries(on date: Date,
                      calendar: Calendar = .autoupdatingCurrent) -> [FoodEntry] {
        let day = LocalDay.interval(containing: date, calendar: calendar)
        let start = day.start
        let end = day.end
        let descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.consumedAt >= start && $0.consumedAt < end },
            sortBy: [SortDescriptor(\.consumedAt, order: .reverse)]
        )
        return (try? fetch(descriptor)) ?? []
    }

    func fetchEntries(from start: Date, to end: Date) -> [FoodEntry] {
        let descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.consumedAt >= start && $0.consumedAt < end },
            sortBy: [SortDescriptor(\.consumedAt, order: .forward)]
        )
        return (try? fetch(descriptor)) ?? []
    }

    func fetchEntry(id: UUID) -> FoodEntry? {
        let descriptor = FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.id == id })
        return try? fetch(descriptor).first
    }

    func fetchCachedProduct(barcode: String) -> BarcodeProductCache? {
        let descriptor = FetchDescriptor<BarcodeProductCache>(
            predicate: #Predicate { $0.barcode == barcode }
        )
        return try? fetch(descriptor).first
    }
}
