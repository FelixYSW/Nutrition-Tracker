import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @AppStorage("appearance") private var appearance = AppAppearance.light.rawValue

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
        // Every scroll view in the app, sheets included, scrolls vertically
        // only (the suggestion chips still scroll sideways: they are wider).
        .verticalScrollingOnly()
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        // Soft ink instead of pure black/white for all text that doesn't set
        // its own colour. `.secondary` and `.tertiary` derive from this.
        .foregroundStyle(AppTheme.ink)
        .onAppear {
            _ = context.loadAppSettings()
            refreshTargetsIfFormulaChanged()
        }
        #if canImport(UIKit)
        // Tap anywhere outside a text field to close the keyboard.
        .background(TapToDismissKeyboard().allowsHitTesting(false))
        #endif
    }

    /// Bumped whenever the target maths changes, so existing users get the
    /// new ranges once, on their next launch. Values edited by hand are kept.
    /// 2: calorie floor on the range minimum, ranges kept on the goal's side
    ///    of maintenance, protein from goal weight at a BMI of 30+.
    static let targetFormulaVersion = 2
    @AppStorage("targetFormulaVersion") private var appliedFormulaVersion = 1

    private func refreshTargetsIfFormulaChanged() {
        guard appliedFormulaVersion < Self.targetFormulaVersion else { return }
        if let profile = profiles.first, !targets.isEmpty {
            TargetUpdater.update(for: profile, in: context)
        }
        appliedFormulaVersion = Self.targetFormulaVersion
    }
}

/// Four destinations in the standard iOS tab bar: Today, Add, Assistant
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
