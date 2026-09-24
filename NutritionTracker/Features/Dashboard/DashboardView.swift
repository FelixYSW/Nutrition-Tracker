import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DraftStore.self) private var store
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var allEntries: [FoodEntry]
    @Query private var targets: [NutritionTarget]
    @State private var now = Date()
    @State private var showSettings = false
    private var entries: [FoodEntry] { LocalDay.entries(allEntries, on: now) }
    private var total: Nutrition { LocalDay.total(entries) }
    private var target: Nutrition { targets.first?.nutrition ?? .zero }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(now, format: .dateTime.weekday(.wide).month(.wide).day()).font(.title2.bold())
                    HStack { CircularNutritionProgress(title: "Calories", consumed: total.calories, target: target.calories, color: .orange)
                        CircularNutritionProgress(title: "Protein", consumed: total.protein, target: target.protein, color: .blue)
                        CircularNutritionProgress(title: "Carbs", consumed: total.carbs, target: target.carbs, color: .green)
                        CircularNutritionProgress(title: "Fat", consumed: total.fat, target: target.fat, color: .purple)
                    }.frame(maxWidth: .infinity)
                    Text("Fibre: \(Int(total.fibre)) / \(Int(target.fibre)) g").font(.subheadline)
                    Text("Today’s food").font(.title3.bold())
                    if entries.isEmpty { EmptyStateView(title: "No food recorded.") }
                    ForEach(entries, id: \.id) { entry in
                        FoodEntryCard(entry: entry)
                            .contextMenu {
                                Button("Edit") { store.edit(entry) }
                                Button("Delete", role: .destructive) { context.delete(entry); try? context.save() }
                            }
                    }
                }.padding()
            }
            .navigationTitle("Dashboard")
            .toolbar { Button { showSettings = true } label: { Image(systemName: "gearshape").accessibilityLabel("Settings") } }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in now = .now }
            .onChange(of: scenePhase) { _, phase in if phase == .active { now = .now } }
            .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); now = .now } }
        }
    }
}
