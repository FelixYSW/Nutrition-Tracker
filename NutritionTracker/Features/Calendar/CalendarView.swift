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

    // What's on screen lives in the router, so the same day, week or month,
    // month page and Days/Trends choice are still showing after visiting
    // another tab.
    private var selectedDate: Date {
        get { router.calendarSelectedDate }
        nonmutating set { router.calendarSelectedDate = newValue }
    }
    /// A week or month opened from Trends; nil shows the single selected day.
    private var period: CalendarSelection? {
        get { router.calendarPeriod }
        nonmutating set { router.calendarPeriod = newValue }
    }
    private var section: Section {
        get { router.calendarSection }
        nonmutating set { router.calendarSection = newValue }
    }
    private var selectedDateBinding: Binding<Date> {
        Binding(get: { router.calendarSelectedDate }, set: { router.calendarSelectedDate = $0 })
    }
    private var monthBinding: Binding<Date> {
        Binding(get: { router.calendarMonth }, set: { router.calendarMonth = $0 })
    }
    private var sectionBinding: Binding<Section> {
        Binding(get: { router.calendarSection }, set: { router.calendarSection = $0 })
    }

    /// Height of the visible page, for the minimum height of the day's content.
    @State private var viewportHeight: CGFloat = 0
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
                    PageHeader(title: "Calendar")

                    Picker("View", selection: sectionBinding) {
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewportHeight = height
            }
            .appPageSurface()
            // The title is drawn in the page, like every tab.
            .toolbar(.hidden, for: .navigationBar)
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
        // The grid isn't on screen yet to follow the date itself.
        router.calendarMonth = CalendarMonthGrid.firstOfMonth(selectedDate)
        withAnimation(.snappy) { section = .day }
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            CalendarMonthGrid(selectedDate: selectedDateBinding,
                              month: monthBinding,
                              entries: allEntries,
                              calorieRange: { targets.effective(on: $0)?.ranges.calories ?? .zero },
                              highlightedPeriod: period?.interval,
                              // Only leaves week/month mode when it's on: an
                              // animated no-op still re-laid out the page.
                              onDayTapped: {
                                  if period != nil { withAnimation(.snappy) { period = nil } }
                              })
                .appCard()

            // At least a screen tall, whatever the day holds. Otherwise tapping
            // a day with less food made the page shorter than the current
            // scroll position, iOS pulled the page back, and the grid - with
            // the date just tapped - jumped under the finger.
            Group {
                if let period {
                    periodContent(period)
                } else {
                    dayContent
                }
            }
            .frame(minHeight: viewportHeight, alignment: .top)
        }
    }

    // MARK: A week or month

    private func periodContent(_ period: CalendarSelection) -> some View {
        let periodEntries = allEntries.filter {
            CalendarMonthGrid.day($0.consumedAt, isIn: period.interval)
        }
        let summary = CalendarSelection.Summary(
            entries: periodEntries, in: period.interval, calorieRange: nil,
            rangeOn: { targets.effective(on: $0)?.ranges.calories })
        let byDay = Dictionary(grouping: periodEntries) { LocalDay.start(of: $0.consumedAt) }
        let days = byDay.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            // The same card as a single day, filled with the daily average
            // over the days logged.
            DaySummaryCard(overline: "Daily average",
                           title: period.title,
                           badge: period.containsToday
                               ? (period.scale == .monthly ? "This month" : "This week") : nil,
                           nutrition: summary.dailyAverage,
                           ranges: targets.effective(on: min(period.interval.end, .now))?.ranges,
                           footnote: summary.description)

            AppSectionHeading(title: "Food log",
                              trailing: periodEntries.isEmpty ? nil
                                : "\(periodEntries.count) item\(periodEntries.count == 1 ? "" : "s")")

            if periodEntries.isEmpty {
                EmptyStateView(title: "No food recorded.",
                               message: "Nothing was logged in this \(period.unitName).",
                               systemImage: "calendar.badge.exclamationmark")
                    .appCard()
            } else {
                // Newest day first. Each day is a heading with its total that
                // starts collapsed; opening it shows that day's foods.
                ForEach(days, id: \.self) { day in
                    let dayEntries = byDay[day] ?? []
                    let isOpen = router.calendarOpenDays.contains(day)
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.snappy) {
                                if isOpen {
                                    router.calendarOpenDays.remove(day)
                                } else {
                                    router.calendarOpenDays.insert(day)
                                }
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                // Chevron before its text, like every chevron.
                                DisclosureChevron(isExpanded: isOpen)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(AppFormatters.dayTitle.string(from: day))
                                    .font(.subheadline.weight(.semibold))
                                Text("\u{00B7} \(dayEntries.count) item\(dayEntries.count == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(AppFormatters.amount(LocalDay.total(dayEntries).calories)) kcal")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: AppTheme.minimumTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(isOpen ? "Hides this day's food" : "Shows this day's food")

                        if isOpen {
                            ForEach(dayEntries) { entry in
                                FoodEntryCard(entry: entry,
                                              onEdit: { editingDraft = FoodEntryDraft(entry: entry) },
                                              onDelete: { entryPendingDeletion = entry })
                            }
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
                           ranges: targets.effective(on: selectedDate)?.ranges)

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
        router.calendarMonth = CalendarMonthGrid.firstOfMonth(requested)
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

        /// `rangeOn` gives each day its own calorie range, so a later change of
        /// ranges doesn't rewrite how earlier days did; `calorieRange` is one
        /// range for every day.
        init(entries: [FoodEntry], in interval: DateInterval, calorieRange: NutrientRange?,
             rangeOn: ((Date) -> NutrientRange?)? = nil,
             now: Date = .now, calendar: Calendar = LocalDay.calendar()) {
            let totals = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.consumedAt) }
                .mapValues { LocalDay.total($0) }
            daysLogged = totals.count
            let end = min(interval.end, calendar.startOfDay(for: now).addingTimeInterval(86_400))
            daysElapsed = max(0, calendar.dateComponents([.day], from: interval.start, to: end).day ?? 0)
            let sum = totals.values.reduce(Nutrition.zero, +)
            dailyAverage = daysLogged > 0 ? sum * (1 / Double(daysLogged)) : .zero
            if rangeOn != nil || (calorieRange?.max ?? 0) > 0 {
                var inRange = 0
                var anyTarget = false
                for (day, total) in totals {
                    guard let range = rangeOn?(day) ?? calorieRange, range.max > 0 else { continue }
                    anyTarget = true
                    if range.state(consumed: total.calories) == .within { inRange += 1 }
                }
                daysInCalorieRange = anyTarget ? inRange : nil
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
    /// The calorie range that applied on a given day.
    let calorieRange: (Date) -> NutrientRange
    /// A week or month shown as a whole: its days are highlighted together
    /// instead of one selected day.
    var highlightedPeriod: DateInterval?
    /// Called when a day is tapped, which leaves week or month mode.
    var onDayTapped: () -> Void = {}

    /// First day of the month on show. Owned by the caller, so the grid keeps
    /// its page when the view is rebuilt (switching tabs or Days/Trends).
    @Binding var month: Date

    init(selectedDate: Binding<Date>, month: Binding<Date>, entries: [FoodEntry],
         calorieRange: @escaping (Date) -> NutrientRange, highlightedPeriod: DateInterval? = nil,
         onDayTapped: @escaping () -> Void = {}) {
        _selectedDate = selectedDate
        _month = month
        self.entries = entries
        self.calorieRange = calorieRange
        self.highlightedPeriod = highlightedPeriod
        self.onDayTapped = onDayTapped
    }

    private var calendar: Calendar { LocalDay.calendar() }

    static func firstOfMonth(_ date: Date) -> Date {
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

    private func rangeState(forCalories kcal: Double, on date: Date) -> RangeState? {
        let range = calorieRange(date)
        guard kcal > 0, range.max > 0 else { return nil }
        return range.state(consumed: kcal)
    }

    /// Whether a day falls in a week or month. The period's end is the first
    /// moment *after* it (next Monday 00:00, the 1st of next month), so it is
    /// excluded - `DateInterval.contains` includes it, which used to outline
    /// one day too many.
    static func day(_ date: Date, isIn period: DateInterval) -> Bool {
        date >= period.start && date < period.end
    }

    private func dayCell(_ date: Date, kcal: Double) -> some View {
        let state = rangeState(forCalories: kcal, on: date)
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
            // Switching day is instant: nothing on the page slides or resizes
            // in an animation, so nothing seems to move.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { selectedDate = date }
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
            legendItem("In range", AppTheme.within)
            legendItem("Under", AppTheme.stillToGo)
            legendItem("Over", AppTheme.over)
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
