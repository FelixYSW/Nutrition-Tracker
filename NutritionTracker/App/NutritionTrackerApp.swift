import SwiftUI
import SwiftData

@main
struct NutritionTrackerApp: App {
    let container: ModelContainer?

    init() {
        container = try? ModelContainer(for: UserProfile.self, NutritionTarget.self,
                                        FoodEntry.self, IngredientItem.self,
                                        BarcodeProductCache.self, CorrectionRecord.self)
    }

    var body: some Scene {
        WindowGroup {
            if let container { RootView().modelContainer(container) }
            else { ContentUnavailableView("Database unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                          description: Text("Your nutrition data could not be opened. Do not uninstall before checking your backup.")) }
        }
    }
}
