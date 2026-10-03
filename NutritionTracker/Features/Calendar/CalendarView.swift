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
    @Query(sort: \NutritionTarget.updatedAt, order: .reverse) private var targets: [NutritionTarget]

    @State private var selectedDate = Date.now
    @State private var section: Section = .day
    @State private var editingDraft: FoodEntryDraft?
    @State private var entryPendingDeletion: FoodEntry?

    enum Section: String, CaseIterable, Identifiable {
        case day, trends
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .day: "Days"
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
            CalendarMonthGrid(selectedDate: $selectedDate,
                              entries: allEntries,
                              calorieRange: targets.first?.ranges.calories ?? .zero)
                .appCard()

            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeading(
                    title: AppFormatters.dayAndMonth.string(from: selectedDate),
                    trailing: LocalDay.isToday(selectedDate) ? "Today" : nil)
                NutritionSummaryView(nutrition: LocalDay.total(entries))
            }
            .appSkyCard()

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

// MARK: - Month grid

/// A month of days, each tinted by how that day's calories sat against the
/// target band: blue in range, grey under, orange over, plain with no data.
/// Colour is never the only signal: every day has an accessibility label that
/// says the state, and the legend names each tint.
struct CalendarMonthGrid: View {
    @Binding var selectedDate: Date
    let entries: [FoodEntry]
    let calorieRange: NutrientRange

    @State private var month: Date

    init(selectedDate: Binding<Date>, entries: [FoodEntry], calorieRange: NutrientRange) {
        _selectedDate = selectedDate
        self.entries = entries
        self.calorieRange = calorieRange
        _month = State(initialValue: Self.firstOfMonth(selectedDate.wrappedValue))
    }

    private var calendar: Calendar { LocalDay.calendar() }

    private static func firstOfMonth(_ date: Date) -> Date {
        let calendar = LocalDay.calendar()
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Calories per local day, built once per render rather than per cell.
    private var caloriesByDay: [Date: Double] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.consumedAt) }
            .mapValues { LocalDay.total($0).calories }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// Leading blanks, then every day of the month.
    private var cells: [Date?] {
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        let dates: [Date?] = days.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month)
        }
        return Array(repeating: nil, count: blanks) + dates
    }

    var body: some View {
        let totals = caloriesByDay
        VStack(spacing: 10) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: AppTheme.minimumTapTarget, height: AppTheme.minimumTapTarget)
                }
                .accessibilityLabel("Previous month")
                Spacer()
                Text(AppFormatters.monthAndYear.string(from: month))
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: AppTheme.minimumTapTarget, height: AppTheme.minimumTapTarget)
                }
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayCell(date, kcal: totals[calendar.startOfDay(for: date)] ?? 0)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }

            legend
        }
        .onChange(of: selectedDate) { _, newValue in
            if !calendar.isDate(newValue, equalTo: month, toGranularity: .month) {
                month = Self.firstOfMonth(newValue)
            }
        }
    }

    private func rangeState(forCalories kcal: Double) -> RangeState? {
        guard kcal > 0, calorieRange.max > 0 else { return nil }
        return calorieRange.state(consumed: kcal)
    }

    private func dayCell(_ date: Date, kcal: Double) -> some View {
        let state = rangeState(forCalories: kcal)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = LocalDay.isToday(date)
        let day = calendar.component(.day, from: date)

        let fill: Color = switch state {
        case .within: AppTheme.within.opacity(0.3)
        case .under: AppTheme.subtleFill
        case .over: AppTheme.over.opacity(0.28)
        case nil: Color.clear
        }

        return Button {
            selectedDate = date
            Haptics.selection()
        } label: {
            Text("\(day)")
                .font(.system(.subheadline, design: .rounded).weight(isToday ? .heavy : .semibold))
                .monospacedDigit()
                .foregroundStyle(state == nil ? Color.secondary : Color.primary)
                .frame(width: 40, height: 40)
                .background(fill, in: Circle())
                .overlay(Circle().stroke(AppTheme.accent, lineWidth: isSelected ? 2 : 0))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(AppFormatters.dayAndMonth.string(from: date)), \(description(of: state))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func description(of state: RangeState?) -> String {
        switch state {
        case .within: "calories in range"
        case .under: "calories under range"
        case .over: "calories over range"
        case nil: "no data"
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem("In range", AppTheme.within.opacity(0.45))
            legendItem("Under", AppTheme.subtleFill)
            legendItem("Over", AppTheme.over.opacity(0.45))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(title)
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) {
            withAnimation(.snappy) { month = Self.firstOfMonth(next) }
        }
    }
}
