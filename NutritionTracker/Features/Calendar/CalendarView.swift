import SwiftUI
import SwiftData

/// Calendar tab: a per-date food log, plus the Trends view (spec section 15).
///
/// Trends lives here rather than in a fifth tab, which the four-tab constraint
/// in section 4 rules out.
struct CalendarView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var allEntries: [FoodEntry]

    @State private var selectedDate = Date.now
    @State private var section: Section = .day
    @State private var editingDraft: FoodEntryDraft?
    @State private var entryPendingDeletion: FoodEntry?

    enum Section: String, CaseIterable, Identifiable {
        case day, trends
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .day: "Day"
            case .trends: "Trends"
            }
        }
    }

    private var entries: [FoodEntry] {
        LocalDay.entries(allEntries, on: selectedDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    Picker("View", selection: $section) {
                        ForEach(Section.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch section {
                    case .day: daySection
                    case .trends: TrendsView(onSelectDate: { date in
                        selectedDate = date
                        withAnimation(.snappy) { section = .day }
                    })
                    }
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingDraft) { draft in
                EditEntrySheet(draft: draft)
            }
            .alert("Delete \(entryPendingDeletion?.name ?? "this food")?",
                   isPresented: Binding(
                    get: { entryPendingDeletion != nil },
                    set: { if !$0 { entryPendingDeletion = nil } })) {
                Button("Delete", role: .destructive) {
                    if let entry = entryPendingDeletion { delete(entry) }
                    entryPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { entryPendingDeletion = nil }
            }
            .onAppear(perform: applyRequestedDate)
            .onChange(of: router.calendarRequestedDate) { _, _ in applyRequestedDate() }
        }
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(AppTheme.accent)
                .appCard()

            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeading(
                    title: "Daily total",
                    trailing: LocalDay.isToday(selectedDate) ? "Today" : nil)
                NutritionSummaryView(nutrition: LocalDay.total(entries))
            }
            .appCard()

            AppSectionHeading(title: "Food log",
                              trailing: entries.isEmpty ? nil
                                : "\(entries.count) item\(entries.count == 1 ? "" : "s")")

            if entries.isEmpty {
                EmptyStateView(title: "No food recorded.",
                               message: "Nothing was logged on this date.",
                               systemImage: "calendar.badge.exclamationmark")
                    .appCard()
            } else {
                ForEach(entries) { entry in
                    FoodEntryCard(entry: entry,
                                  onEdit: { editingDraft = FoodEntryDraft(entry: entry) },
                                  onDelete: { entryPendingDeletion = entry })
                }
            }
        }
    }

    private func applyRequestedDate() {
        guard let requested = router.calendarRequestedDate else { return }
        selectedDate = requested
        section = .day
        router.calendarRequestedDate = nil
    }

    private func delete(_ entry: FoodEntry) {
        if let photoPath = entry.photoPath {
            ImageStore.delete(relativePath: photoPath)
        }
        context.delete(entry)
        try? context.save()
        Haptics.success()
    }
}
