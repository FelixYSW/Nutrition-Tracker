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
        .onAppear { _ = context.loadAppSettings() }
    }
}

/// Exactly four tabs. Settings and the assistant are nav-bar items on the
/// Dashboard, not tabs (spec sections 4 and 29A).
struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        TabView(selection: Binding(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 }
        )) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.pie.fill") }
                .tag(AppRouter.Tab.dashboard)

            ScanView()
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                .tag(AppRouter.Tab.scan)

            AddMealView()
                .tabItem { Label("Add Meal", systemImage: "plus.circle.fill") }
                .tag(AppRouter.Tab.addMeal)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppRouter.Tab.calendar)
        }
        .tint(AppTheme.accent)
    }
}
