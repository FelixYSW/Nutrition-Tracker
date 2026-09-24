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
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TODAY").font(.caption.bold()).tracking(1.4).foregroundStyle(AppTheme.accent)
                        Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.largeTitle.bold()).minimumScaleFactor(0.8)
                    }.padding(.bottom, 2)

                    HStack(spacing: 18) {
                        CircularNutritionProgress(title: "Calories", consumed: total.calories,
                                                  target: target.calories, color: AppTheme.accent, size: 112)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Daily energy").font(.subheadline).foregroundStyle(.secondary)
                            Text("\(Int(max(0, target.calories - total.calories)))")
                                .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                            Text("kcal remaining").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity).appCard()

                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionHeading(title: "Macros")
                        HStack {
                            CircularNutritionProgress(title: "Protein", consumed: total.protein, target: target.protein, color: .blue)
                            Spacer(minLength: 2)
                            CircularNutritionProgress(title: "Carbs", consumed: total.carbs, target: target.carbs, color: .orange)
                            Spacer(minLength: 2)
                            CircularNutritionProgress(title: "Fat", consumed: total.fat, target: target.fat, color: .purple)
                        }
                        HStack {
                            Text("Fibre").font(.subheadline)
                            Spacer()
                            Text("\(Int(total.fibre)) / \(Int(target.fibre)) g")
                                .font(.subheadline.bold()).monospacedDigit()
                        }
                        ProgressView(value: min(total.fibre, target.fibre), total: max(target.fibre, 1))
                            .tint(AppTheme.accent)
                    }.appCard()

                    AppSectionHeading(title: "Food log", trailing: "\(entries.count) items")
                        .padding(.top, 6)
                    if entries.isEmpty { EmptyStateView(title: "No food recorded.") }
                    ForEach(entries, id: \.id) { entry in
                        FoodEntryCard(entry: entry)
                            .contextMenu {
                                Button("Edit") { store.edit(entry) }
                                Button("Delete", role: .destructive) { context.delete(entry); try? context.save() }
                            }
                    }
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { showSettings = true } label: { Image(systemName: "gearshape.fill").accessibilityLabel("Settings") } }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in now = .now }
            .onChange(of: scenePhase) { _, phase in if phase == .active { now = .now } }
            .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); now = .now } }
        }
    }
}
