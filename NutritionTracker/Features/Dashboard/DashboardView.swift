import SwiftUI
import SwiftData

/// One local calendar day at a time: today by default, with buttons to step
/// back through earlier days and a button back to today (spec sections 13, 14).
///
/// Totals are computed by filtering `FoodEntry.consumedAt` into the shown
/// day's interval. Nothing is stored per day, so at midnight the day simply
/// changes and today's totals read zero while yesterday's entries survive.
struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(DayChangeObserver.self) private var dayObserver
    @Environment(AppRouter.self) private var router

    @Query private var profiles: [UserProfile]
    @Query private var targets: [NutritionTarget]
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var allEntries: [FoodEntry]

    @State private var isShowingSettings = false
    @State private var isShowingWeightCheckIn = false
    /// "Later" on the check-in card hides it for a few days.
    @AppStorage("weightCheckIn.snoozedUntil") private var checkInSnoozedUntil = 0.0
    @AppStorage(UserProfile.checkInIntervalKey)
    private var checkInIntervalDays = UserProfile.defaultCheckInIntervalDays
    @State private var editingDraft: FoodEntryDraft?
    @State private var entryPendingDeletion: FoodEntry?

    /// Start of an earlier day being looked at; nil shows today. Kept by the
    /// router, so it's still that day after visiting another tab.
    private var pickedDay: Date? {
        get { router.todayPickedDay }
        nonmutating set { router.todayPickedDay = newValue }
    }

    /// Re-queried whenever the day changes, because the observer's published
    /// day start is read here.
    private var today: Date { dayObserver.currentDayStart }

    /// The day on screen. Never later than today, even if today moves on
    /// while an earlier day is shown.
    private var shownDay: Date { min(pickedDay ?? today, today) }
    private var isShowingToday: Bool { shownDay >= today }

    private var entries: [FoodEntry] {
        LocalDay.entries(allEntries, on: shownDay)
    }

    private var consumed: Nutrition {
        LocalDay.total(entries)
    }

    private var ranges: NutritionTargetRanges {
        // The ranges that applied on the day shown, not today's.
        targets.effective(on: shownDay)?.ranges ?? .zero
    }

    /// What the profile says the body uses in a day, for the deficit line.
    private var maintenance: Double? {
        profiles.first.map { NutritionTargetCalculator.calculate(profile: $0).tdee }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    header
                    dayControls
                    CalorieHeroCard(consumed: consumed.calories, range: ranges.calories,
                                    isDayOver: !isShowingToday, maintenance: maintenance)
                    ringsCard
                    if isShowingToday, let profile = profiles.first,
                       profile.isCheckInDue(intervalDays: checkInIntervalDays),
                       Date.now.timeIntervalSinceReferenceDate >= checkInSnoozedUntil {
                        WeightCheckInCard(profile: profile,
                                          onUpdate: { isShowingWeightCheckIn = true },
                                          onLater: { snoozeCheckIn() })
                    }
                    entriesSection
                }
                .appPageContent()
            }
            .appPageSurface()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                // Pull-to-refresh re-checks the local day, which also covers
                // returning to the app after midnight.
                dayObserver.refresh()
            }
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
            .sheet(isPresented: $isShowingWeightCheckIn) {
                if let profile = profiles.first { WeightCheckInSheet(profile: profile) }
            }
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
        }
    }

    // MARK: Sections

    private var header: some View {
        PageHeader(title: AppFormatters.dayAndMonth.string(from: shownDay),
                   subtitle: dayLabel) {
            GlassIconButton(systemImage: "person", label: "Settings") {
                isShowingSettings = true
            }
        }
    }

    /// "Wednesday" today; "Yesterday · Tuesday" or "Monday" for earlier days.
    private var dayLabel: String {
        let weekday = AppFormatters.weekdayName.string(from: shownDay)
        if isShowingToday { return weekday }
        let calendar = LocalDay.calendar()
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(shownDay, inSameDayAs: yesterday) {
            return "Yesterday \u{00B7} \(weekday)"
        }
        return weekday
    }

    /// Back a day, forward a day (never past today), and back to today.
    private var dayControls: some View {
        HStack(spacing: 10) {
            GlassIconButton(systemImage: "chevron.left", label: "Previous day") {
                step(by: -1)
            }
            GlassIconButton(systemImage: "chevron.right", label: "Next day") {
                step(by: 1)
            }
            .disabled(isShowingToday)
            .opacity(isShowingToday ? 0.35 : 1)

            Spacer(minLength: 8)

            // Always in place, so the row never shifts. Drawn like the day
            // arrows - the same glass and ink - and faded and disabled while
            // today is already showing, like the forward arrow.
            Button {
                withAnimation(.snappy) { pickedDay = nil }
                Haptics.selection()
            } label: {
                Text("Today")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 18)
                    .frame(minHeight: AppTheme.minimumTapTarget)
                    .appGlass(in: Capsule(), interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isShowingToday)
            .opacity(isShowingToday ? 0.35 : 1)
            .accessibilityLabel("Back to today")
        }
    }

    private func snoozeCheckIn() {
        let threeDays: TimeInterval = 3 * 24 * 60 * 60
        withAnimation(.snappy) {
            checkInSnoozedUntil = Date.now.addingTimeInterval(threeDays).timeIntervalSinceReferenceDate
        }
    }

    private func step(by days: Int) {
        let calendar = LocalDay.calendar()
        guard let next = calendar.date(byAdding: .day, value: days, to: shownDay) else { return }
        let day = calendar.startOfDay(for: next)
        // No days after today.
        guard day <= today else { return }
        withAnimation(.snappy) { pickedDay = day >= today ? nil : day }
        Haptics.selection()
    }

    private var ringsCard: some View {
        // Four small rings in one row: protein, carbs, fat and fibre. Calories
        // get the hero card above.
        HStack(alignment: .top, spacing: 4) {
            ForEach([Nutrient.protein, .carbs, .fat, .fibre]) { nutrient in
                CompactMacroRing(nutrient: nutrient,
                                 consumed: consumed[nutrient],
                                 range: ranges[nutrient],
                                 isDayOver: !isShowingToday)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground, in: RoundedRectangle(
            cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            .stroke(AppTheme.cardBorder, lineWidth: 1))
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeading(title: isShowingToday ? "Today's food" : "Food log",
                              trailing: entries.isEmpty ? nil : "\(entries.count)")

            if entries.isEmpty {
                if isShowingToday {
                    EmptyStateView(title: "Nothing logged yet",
                                   message: "Add food by hand, or tell the Assistant what you ate.",
                                   systemImage: "fork.knife",
                                   actionTitle: "Add food") {
                        router.selectedTab = .addMeal
                    }
                    .appCard()
                } else {
                    EmptyStateView(title: "Nothing logged",
                                   message: "No food was recorded on this day.",
                                   systemImage: "calendar.badge.exclamationmark")
                        .appCard()
                }
            } else {
                ForEach(entries) { entry in
                    FoodEntryCard(entry: entry,
                                  onEdit: { editingDraft = FoodEntryDraft(entry: entry) },
                                  onDelete: { entryPendingDeletion = entry })
                }
            }
        }
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

/// Horizontal equivalent of the range ring, for secondary nutrients.
struct RangeBar: View {
    let consumed: Double
    let range: NutrientRange
    let nutrient: Nutrient
    /// Fill and in-range band colours. Default to the nutrient's own; the
    /// calorie bars use an ink fill on a green band, like the calorie ring.
    var fill: Color?
    var band: Color?

    var body: some View {
        let state = range.state(consumed: consumed)
        let fractions = range.bandFractions()

        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.subtleFill)

                // Shaded in-range zone.
                Capsule()
                    .fill((band ?? AppTheme.color(for: nutrient)).opacity(band == nil ? 0.22 : 0.35))
                    .frame(width: max(0, width * (1 - fractions.start)))
                    .offset(x: width * fractions.start)

                Capsule()
                    .fill(fill ?? AppTheme.color(for: state, nutrient: nutrient))
                    .frame(width: max(2, width * min(1, range.progress(consumed: consumed))))
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nutrient.displayName)
        .accessibilityValue("\(AppFormatters.amount(consumed)) of "
                            + "\(AppFormatters.range(range)) \(nutrient.unitLabel), \(state.rawValue) range")
    }
}

/// Sheet for editing an already-saved entry, reusing the Add Meal draft editor
/// so there is one editing implementation.
struct EditEntrySheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State var draft: FoodEntryDraft

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppTheme.pageSpacing) {
                    FoodDraftCard(draft: $draft, onDelete: nil, showsTimePicker: true)
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Edit food")
            .keyboardDismissControls()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!draft.isSaveable)
                }
            }
        }
    }

    private func save() {
        guard let entry = context.fetchEntry(id: draft.id) else {
            dismiss()
            return
        }
        draft.apply(to: entry)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
