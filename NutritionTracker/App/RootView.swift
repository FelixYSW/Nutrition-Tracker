import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @AppStorage("appearance") private var appearance = AppAppearance.light.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // Reduce Motion: changes happen in place instead of springing,
        // sliding or scaling. Covers every withAnimation in the app.
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        // Soft ink instead of pure black/white for all text that doesn't set
        // its own colour, with `.secondary` and `.tertiary` given explicitly
        // so grey captions keep readable contrast.
        .foregroundStyle(AppTheme.ink, AppTheme.inkSecondary, AppTheme.inkTertiary)
        .onAppear {
            _ = context.loadAppSettings()
            context.seedWeightHistoryIfNeeded()
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

/// Five destinations in the standard iOS tab bar: Today, Add, Foods,
/// Assistant and Calendar. Settings is a button on Today.
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
                // A plain plus: a filled circle drew as a heavy grey disc in
                // the glass tab bar, unlike the line icons beside it.
                .tabItem { Label("Add", systemImage: "plus") }
                .tag(AppRouter.Tab.addMeal)

            ShownOnlyWhenSelected(tab: .foods) { FoodsView() }
                .tabItem { Label("Foods", systemImage: "fork.knife") }
                .tag(AppRouter.Tab.foods)

            AssistantView()
                .tabItem { Label("Assistant", systemImage: "sparkles") }
                .tag(AppRouter.Tab.assistant)

            ShownOnlyWhenSelected(tab: .calendar) { CalendarView() }
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppRouter.Tab.calendar)
        }
    }
}

/// A tab's page, built only while its tab is showing.
///
/// iOS keeps every visited tab alive, and a live tab redraws whenever the
/// food log changes or a sheet closes anywhere in the app - Foods and
/// Calendar read the whole log to do it, which stalled sheets closing on
/// other tabs. Only tabs whose state lives in `AppRouter` (or that have
/// none) use this; Add food and the assistant keep their page alive.
private struct ShownOnlyWhenSelected<Content: View>: View {
    @Environment(AppRouter.self) private var router
    let tab: AppRouter.Tab
    @ViewBuilder var content: () -> Content

    var body: some View {
        if router.selectedTab == tab {
            content()
        } else {
            AppTheme.background.ignoresSafeArea()
        }
    }
}
