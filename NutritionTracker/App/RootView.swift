import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @Query private var profiles: [UserProfile]
    @Query private var targets: [NutritionTarget]

    private var hasCompletedOnboarding: Bool {
        // Onboarding is complete once a profile and targets exist. Keyed off real
        // data rather than a flag alone, so a restored backup lands straight on
        // the Dashboard.
        !profiles.isEmpty && !targets.isEmpty
    }

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        // Full-bleed: no fixed-width container, no letterboxing on any iPhone.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .tint(AppTheme.accent)
        // Soft ink instead of pure black/white for all text that doesn't set
        // its own colour. `.secondary` and `.tertiary` derive from this.
        .foregroundStyle(AppTheme.ink)
        .onAppear { _ = context.loadAppSettings() }
    }
}

/// Five destinations in the standard iOS tab bar: Today, Scan, Add, Assistant
/// and Calendar. Settings is a button on Today.
///
/// The system tab bar reserves its own space, so page content and bottom
/// controls (like Add Meal's save button) always sit above it rather than
/// being covered.
struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        TabView(selection: Binding(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 }
        )) {
            DashboardView()
                .tabItem { Label("Today", systemImage: "chart.pie.fill") }
                .tag(AppRouter.Tab.dashboard)

            ScanView()
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                .tag(AppRouter.Tab.scan)

            AddMealView()
                .tabItem { Label("Add", systemImage: "plus.circle.fill") }
                .tag(AppRouter.Tab.addMeal)

            AssistantView()
                .tabItem { Label("Assistant", systemImage: "sparkles") }
                .tag(AppRouter.Tab.assistant)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppRouter.Tab.calendar)
        }
    }
}
