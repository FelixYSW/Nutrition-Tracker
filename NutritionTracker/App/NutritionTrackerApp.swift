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
        AppTheme.applyTabBarColours()
        #endif
        // Start watching foreground/background from launch, so an assistant
        // request cut off by switching apps is recognised and resent.
        _ = AppActivity.shared
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

/// Cross-tab navigation: drafts handed to Add Meal, and Add Meal's Photo and
/// Describe buttons opening the assistant, so the selected tab and what's
/// being handed over live above the individual tab views (spec sections 28, 33).
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case dashboard, addMeal, foods, assistant, calendar
    }

    var selectedTab: Tab = .dashboard

    /// What Add Meal asked the assistant to start with.
    enum AssistantRequest: Equatable {
        /// Open the camera for a food photo.
        case photo
        /// Open the keyboard to describe what was eaten.
        case describe
    }

    /// Picked up and cleared by the Assistant tab.
    var assistantRequest: AssistantRequest?

    func openAssistant(_ request: AssistantRequest) {
        assistantRequest = request
        selectedTab = .assistant
    }

    /// Draft handed over from elsewhere in the app. Add Meal
    /// picks this up, shows it for review, and clears it.
    var pendingDrafts: [FoodEntryDraft] = []

    /// One-line explanation shown above the handed-over drafts, e.g. where the
    /// figures came from or why nothing could be filled in.
    var pendingNotice: String?

    /// Date the Calendar tab should show. Set when the user taps a point in Trends.
    var calendarRequestedDate: Date?

    // MARK: What each page is showing
    //
    // Kept here, above the tab views, so leaving a page and coming back -
    // or switching between Days and Trends - shows exactly what was on screen
    // before, for as long as the app stays open. Memory only: a fresh launch
    // starts on today again.

    /// Start of the earlier day shown on Today; nil shows today itself.
    var todayPickedDay: Date?

    var calendarSection: CalendarView.Section = .day
    var calendarSelectedDate: Date = .now
    /// A week or month opened from Trends; nil shows the selected day.
    var calendarPeriod: CalendarSelection?
    /// Days opened in a week's or month's food log (each starts collapsed).
    var calendarOpenDays: Set<Date> = []
    /// First day of the month the Calendar grid is paged to.
    var calendarMonth: Date = CalendarMonthGrid.firstOfMonth(.now)

    var trendsScale: TrendScale = .daily
    var trendsNutrient: Nutrient = .calories

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
