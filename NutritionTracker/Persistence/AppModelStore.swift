import Foundation
import SwiftData

enum AppModelStore {
    static func makeContainer(directory: URL? = nil) throws -> ModelContainer {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // Keep SwiftData's original default filename so an existing installation keeps its data.
        let storeURL = support.appendingPathComponent("default.store")
        let schema = Schema([UserProfile.self, NutritionTarget.self, FoodEntry.self,
                             IngredientItem.self, BarcodeProductCache.self, CorrectionRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
