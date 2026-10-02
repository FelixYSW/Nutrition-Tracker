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
        .onAppear { _ = context.loadAppSettings() }
    }
}

/// Five destinations behind a floating glass bar: Today, Scan, Add (centre,
/// emphasised), Assistant and Calendar. Settings is a button on Today.
///
/// The system tab bar is hidden and replaced by `FloatingTabBar`; `TabView`
/// is kept underneath so each tab holds on to its state (for example unsaved
/// Add Meal drafts) while another tab is showing.
struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        TabView(selection: Binding(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 }
        )) {
            DashboardView()
                .toolbar(.hidden, for: .tabBar)
                .tag(AppRouter.Tab.dashboard)

            ScanView()
                .toolbar(.hidden, for: .tabBar)
                .tag(AppRouter.Tab.scan)

            AddMealView()
                .toolbar(.hidden, for: .tabBar)
                .tag(AppRouter.Tab.addMeal)

            AssistantView()
                .toolbar(.hidden, for: .tabBar)
                .tag(AppRouter.Tab.assistant)

            CalendarView()
                .toolbar(.hidden, for: .tabBar)
                .tag(AppRouter.Tab.calendar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selection: Binding(
                get: { router.selectedTab },
                set: { router.selectedTab = $0 }))
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}

/// Floating glass tab bar with Add as a filled button in the middle.
struct FloatingTabBar: View {
    @Binding var selection: AppRouter.Tab

    var body: some View {
        HStack(spacing: 0) {
            item(.dashboard, title: "Today", systemImage: "chart.pie.fill")
            item(.scan, title: "Scan", systemImage: "camera.viewfinder")
            addButton
            item(.assistant, title: "Assistant", systemImage: "sparkles")
            item(.calendar, title: "Calendar", systemImage: "calendar")
        }
        .padding(8)
        .appGlass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func item(_ tab: AppRouter.Tab, title: String, systemImage: String) -> some View {
        let isSelected = selection == tab
        return Button {
            guard selection != tab else { return }
            Haptics.selection()
            withAnimation(.snappy) { selection = tab }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isSelected ? AppTheme.accentFill.opacity(0.2) : Color.clear,
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var addButton: some View {
        Button {
            Haptics.selection()
            withAnimation(.snappy) { selection = .addMeal }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(AppTheme.onAccent)
                .frame(width: 52, height: 52)
                .background(AppTheme.accentFill, in: Circle())
                .overlay(
                    Circle().stroke(AppTheme.accentFill.opacity(selection == .addMeal ? 0.35 : 0),
                                    lineWidth: 5))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Add meal")
        .accessibilityAddTraits(selection == .addMeal ? [.isButton, .isSelected] : .isButton)
    }
}
