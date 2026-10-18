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
    /// A week or month opened from Trends; nil shows the single selected day.
    @State private var period: CalendarSelection?
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
                    case .trends: TrendsView(onSelect: { selection in
                        open(selection)
                    })
                    }
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.large)
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

    /// Opens a bar from Trends: a day on its own, or a whole week or month.
    private func open(_ selection: CalendarSelection) {
        if selection.isPeriod {
            period = selection
            // Shows the grid on the period's month (its start, never the future).
            selectedDate = min(selection.interval.start, .now)
        } else {
            period = nil
            selectedDate = selection.interval.start
        }
        withAnimation(.snappy) { section = .day }
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            CalendarMonthGrid(selectedDate: $selectedDate,
                              entries: allEntries,
                              calorieRange: targets.first?.ranges.calories ?? .zero,
                              highlightedPeriod: period?.interval,
                              onDayTapped: { withAnimation(.snappy) { period = nil } })
                .appCard()

            if let period {
                periodContent(period)
            } else {
                dayContent
            }
        }
    }

    // MARK: A week or month

    private func periodContent(_ period: CalendarSelection) -> some View {
        let periodEntries = allEntries.filter {
            CalendarMonthGrid.day($0.consumedAt, isIn: period.interval)
        }
        let summary = CalendarSelection.Summary(entries: periodEntries, in: period.interval,
                                                calorieRange: targets.first?.ranges.calories)
        let byDay = Dictionary(grouping: periodEntries) { LocalDay.start(of: $0.consumedAt) }
        let days = byDay.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeading(title: period.title, trailing: period.containsToday ? "Now" : nil)
                if summary.daysLogged > 0 {
                    Text("Daily average")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    NutritionRangeSummaryView(nutrition: summary.dailyAverage,
                                              ranges: targets.first?.ranges,
                                              isComplete: !period.containsToday)
                }
                Text(summary.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appSkyCard()

            AppSectionHeading(title: "Food log",
                              trailing: periodEntries.isEmpty ? nil
                                : "\(periodEntries.count) item\(periodEntries.count == 1 ? "" : "s")")

            if periodEntries.isEmpty {
                EmptyStateView(title: "No food recorded.",
                               message: "Nothing was logged in this \(period.unitName).",
                               systemImage: "calendar.badge.exclamationmark")
                    .appCard()
            } else {
                // Newest day first, each under its own heading with its total.
                ForEach(days, id: \.self) { day in
                    let dayEntries = byDay[day] ?? []
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(AppFormatters.dayTitle.string(from: day))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(AppFormatters.amount(LocalDay.total(dayEntries).calories)) kcal")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        ForEach(dayEntries) { entry in
                            FoodEntryCard(entry: entry,
                                          onEdit: { editingDraft = FoodEntryDraft(entry: entry) },
                                          onDelete: { entryPendingDeletion = entry })
                        }
                    }
                }
            }

            Text("Tap a day in the calendar to see just that day.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: A single day

    private var dayContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            DaySummaryCard(date: selectedDate,
                           nutrition: LocalDay.total(entries),
                           ranges: targets.first?.ranges)

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
        period = nil
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

// MARK: - Selection

/// What a tapped Trends bar opens in the Calendar: a day, week or month.
struct CalendarSelection: Equatable {
    var interval: DateInterval
    var scale: TrendScale

    var isPeriod: Bool { scale != .daily }

    var unitName: String {
        switch scale {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        }
    }

    /// "6 Oct – 12 Oct" for a week, "October 2026" for a month.
    var title: String {
        switch scale {
        case .daily:
            AppFormatters.dayAndMonth.string(from: interval.start)
        case .weekly:
            AppFormatters.dayAndMonth.string(from: interval.start) + " \u{2013} "
                + AppFormatters.dayAndMonth.string(from: interval.end.addingTimeInterval(-1))
        case .monthly:
            AppFormatters.monthAndYear.string(from: interval.start)
        }
    }

    var containsToday: Bool { interval.contains(.now) }

    /// The period's figures for the summary card.
    struct Summary: Equatable {
        var daysLogged: Int
        /// Days of the period that have happened so far (the current week or
        /// month isn't over yet).
        var daysElapsed: Int
        var dailyAverage: Nutrition
        /// Logged days with calories within range, or nil without a target.
        var daysInCalorieRange: Int?

        init(entries: [FoodEntry], in interval: DateInterval, calorieRange: NutrientRange?,
             now: Date = .now, calendar: Calendar = LocalDay.calendar()) {
            let totals = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.consumedAt) }
                .mapValues { LocalDay.total($0) }
            daysLogged = totals.count
            let end = min(interval.end, calendar.startOfDay(for: now).addingTimeInterval(86_400))
            daysElapsed = max(0, calendar.dateComponents([.day], from: interval.start, to: end).day ?? 0)
            let sum = totals.values.reduce(Nutrition.zero, +)
            dailyAverage = daysLogged > 0 ? sum * (1 / Double(daysLogged)) : .zero
            if let calorieRange, calorieRange.max > 0 {
                daysInCalorieRange = totals.values.filter {
                    calorieRange.state(consumed: $0.calories) == .within
                }.count
            } else {
                daysInCalorieRange = nil
            }
        }

        /// "5 of 7 days logged · calories in range on 3."
        var description: String {
            guard daysLogged > 0 else { return "No days logged yet." }
            var text = "\(daysLogged) of \(daysElapsed) day\(daysElapsed == 1 ? "" : "s") logged"
            if let daysInCalorieRange {
                text += " \u{00B7} calories in range on \(daysInCalorieRange)"
            }
            return text + "."
        }
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
    /// A week or month shown as a whole: its days are highlighted together
    /// instead of one selected day.
    var highlightedPeriod: DateInterval?
    /// Called when a day is tapped, which leaves week or month mode.
    var onDayTapped: () -> Void = {}

    @State private var month: Date

    init(selectedDate: Binding<Date>, entries: [FoodEntry], calorieRange: NutrientRange,
         highlightedPeriod: DateInterval? = nil, onDayTapped: @escaping () -> Void = {}) {
        _selectedDate = selectedDate
        self.entries = entries
        self.calorieRange = calorieRange
        self.highlightedPeriod = highlightedPeriod
        self.onDayTapped = onDayTapped
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

    /// Whether a day falls in a week or month. The period's end is the first
    /// moment *after* it (next Monday 00:00, the 1st of next month), so it is
    /// excluded - `DateInterval.contains` includes it, which used to outline
    /// one day too many.
    static func day(_ date: Date, isIn period: DateInterval) -> Bool {
        date >= period.start && date < period.end
    }

    private func dayCell(_ date: Date, kcal: Double) -> some View {
        let state = rangeState(forCalories: kcal)
        let inPeriod = highlightedPeriod.map { Self.day(date, isIn: $0) } ?? false
        // One selected day, or every day of the week or month shown - all
        // get the same outline.
        let isSelected = highlightedPeriod == nil
            ? calendar.isDate(date, inSameDayAs: selectedDate)
            : inPeriod
        let isToday = LocalDay.isToday(date)
        let day = calendar.component(.day, from: date)

        let fill: Color = switch state {
        case .within: AppTheme.within.opacity(0.3)
        // Under is a plain neutral circle, past or present.
        case .under: AppTheme.subtleFill
        case .over: AppTheme.over.opacity(0.28)
        case nil: Color.clear
        }

        return Button {
            selectedDate = date
            onDayTapped()
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
        case .under: "calories below the minimum"
        case .over: "calories over the maximum"
        case nil: "no data"
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem("In range", AppTheme.within.opacity(0.45))
            legendItem("Under", AppTheme.stillToGo)
            legendItem("Over max", AppTheme.over.opacity(0.45))
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
