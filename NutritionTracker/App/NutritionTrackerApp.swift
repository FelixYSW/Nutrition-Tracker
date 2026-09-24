import SwiftUI
import SwiftData

@main
struct NutritionTrackerApp: App {
    let container: ModelContainer?

    init() {
        container = try? AppModelStore.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            if let container { RootView().modelContainer(container) }
            else { ContentUnavailableView("Database unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                          description: Text("Your nutrition data could not be opened. Do not uninstall before checking your backup.")) }
        }
    }
}
