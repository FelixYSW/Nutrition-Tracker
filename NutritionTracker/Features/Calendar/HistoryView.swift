import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var allEntries: [FoodEntry]
    @State private var selected = Date()
    private var entries: [FoodEntry] { LocalDay.entries(allEntries, on: selected) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DatePicker("Date", selection: $selected, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    NutritionSummaryView(nutrition: LocalDay.total(entries))
                    if entries.isEmpty { EmptyStateView(title: "No food recorded.") }
                    ForEach(entries, id: \.id) { FoodEntryCard(entry: $0) }
                }.padding()
            }.navigationTitle("Calendar")
        }
    }
}
