import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var allEntries: [FoodEntry]
    @State private var selected = Date()
    private var entries: [FoodEntry] { LocalDay.entries(allEntries, on: selected) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("YOUR HISTORY").font(.caption.bold()).tracking(1.4).foregroundStyle(AppTheme.accent)
                        Text("Food calendar").font(.largeTitle.bold())
                    }
                    DatePicker("Date", selection: $selected, displayedComponents: .date)
                        .datePickerStyle(.graphical).tint(AppTheme.accent).appCard()
                    VStack(alignment: .leading, spacing: 14) {
                        AppSectionHeading(title: "Daily total")
                        NutritionSummaryView(nutrition: LocalDay.total(entries))
                    }.appCard()
                    AppSectionHeading(title: "Food log", trailing: "\(entries.count) items")
                    if entries.isEmpty { EmptyStateView(title: "No food recorded.") }
                    ForEach(entries, id: \.id) { FoodEntryCard(entry: $0) }
                }.appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
