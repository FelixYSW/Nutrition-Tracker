import SwiftUI
import SwiftData

@main
struct NutritionTrackerApp: App {
    private let container = AppModelContainer.makeContainer()

    @State private var dayObserver = DayChangeObserver()
    @State private var appRouter = AppRouter()

    init() {
        #if canImport(UIKit)
        AppTheme.applyNavigationBarTextColour()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dayObserver)
                .environment(appRouter)
        }
        .modelContainer(container)
    }
}

/// Cross-tab navigation. The photo and barcode flows both end in Add Meal with a
/// prefilled draft, so the selected tab and the pending draft have to live above
/// the individual tab views (spec sections 28 and 33).
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case dashboard, scan, addMeal, assistant, calendar
    }

    var selectedTab: Tab = .dashboard

    /// Draft handed over from Scan (photo or barcode) or the assistant. Add Meal
    /// picks this up, shows it for review, and clears it.
    var pendingDrafts: [FoodEntryDraft] = []

    /// One-line explanation shown above the handed-over drafts, e.g. where the
    /// figures came from or why nothing could be filled in.
    var pendingNotice: String?

    /// Date the Calendar tab should show. Set when the user taps a point in Trends.
    var calendarRequestedDate: Date?

    func present(drafts: [FoodEntryDraft], notice: String? = nil) {
        pendingNotice = notice
        pendingDrafts = drafts
        selectedTab = .addMeal
    }

    func showCalendar(on date: Date) {
        calendarRequestedDate = date
        selectedTab = .calendar
    }

    func consumePendingDrafts() -> (drafts: [FoodEntryDraft], notice: String?) {
        let handover = (pendingDrafts, pendingNotice)
        pendingDrafts = []
        pendingNotice = nil
        return handover
    }
}
