import SwiftUI
import SwiftData

struct RootView: View {
    @Query private var profiles: [UserProfile]
    @State private var drafts = DraftStore()
    var body: some View {
        Group {
            if profiles.isEmpty { OnboardingView() }
            else {
                TabView(selection: $drafts.selectedTab) {
                    DashboardView().tabItem { Label("Dashboard", systemImage: "circle.grid.2x2") }.tag(0)
                    ScanView().tabItem { Label("Scan", systemImage: "camera.viewfinder") }.tag(1)
                    AddMealView().tabItem { Label("Add Meal", systemImage: "plus.circle") }.tag(2)
                    HistoryView().tabItem { Label("Calendar", systemImage: "calendar") }.tag(3)
                }
            }
        }.environment(drafts)
    }
}
