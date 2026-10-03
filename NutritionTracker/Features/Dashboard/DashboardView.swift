import SwiftUI
import SwiftData

/// Always shows the current local calendar day (spec sections 13, 14).
///
/// Totals are computed by filtering `FoodEntry.consumedAt` into today's
/// interval. Nothing is stored per day, so at midnight the day simply changes
/// and the totals read zero while the targets and yesterday's entries survive.
struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(DayChangeObserver.self) private var dayObserver
    @Environment(AppRouter.self) private var router

    @Query private var profiles: [UserProfile]
    @Query private var targets: [NutritionTarget]
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var allEntries: [FoodEntry]

    @State private var isShowingSettings = false
    @State private var editingDraft: FoodEntryDraft?
    @State private var entryPendingDeletion: FoodEntry?

    /// Re-queried whenever the day changes, because the observer's published
    /// day start is read here.
    private var today: Date { dayObserver.currentDayStart }

    private var entries: [FoodEntry] {
        LocalDay.entries(allEntries, on: today)
    }

    private var consumed: Nutrition {
        LocalDay.total(entries)
    }

    private var ranges: NutritionTargetRanges {
        targets.sorted { $0.updatedAt > $1.updatedAt }.first?.ranges ?? .zero
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    header
                    CalorieHeroCard(consumed: consumed.calories, range: ranges.calories)
                    ringsCard
                    statusMessages
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppFormatters.weekdayName.string(from: today))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(AppFormatters.dayAndMonth.string(from: today))
                    .font(.system(.title, design: .rounded).weight(.heavy))
                    .contentTransition(.numericText())
            }
            Spacer()
            GlassIconButton(systemImage: "person.crop.circle",
                            label: "Settings") {
                isShowingSettings = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ringsCard: some View {
        // Four small rings in one row: protein, carbs, fat and fibre. Calories
        // get the hero card above.
        HStack(alignment: .top, spacing: 4) {
            ForEach([Nutrient.protein, .carbs, .fat, .fibre]) { nutrient in
                CompactMacroRing(nutrient: nutrient,
                                 consumed: consumed[nutrient],
                                 range: ranges[nutrient])
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground, in: RoundedRectangle(
            cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var statusMessages: some View {
        let flagged = Nutrient.allCases.filter {
            ranges[$0].max > 0 && ranges[$0].state(consumed: consumed[$0]) == .over
        }
        let lowest = Nutrient.allCases
            .filter { ranges[$0].max > 0 && ranges[$0].state(consumed: consumed[$0]) == .under }
            .max { lhs, rhs in
                (ranges[lhs].min - consumed[lhs]) < (ranges[rhs].min - consumed[rhs])
            }

        if !flagged.isEmpty || lowest != nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(flagged) { nutrient in
                    RangeStatusMessage(nutrient: nutrient,
                                       consumed: consumed[nutrient],
                                       range: ranges[nutrient])
                }
                if let lowest {
                    RangeStatusMessage(nutrient: lowest,
                                       consumed: consumed[lowest],
                                       range: ranges[lowest])
                }
            }
            .appCard()
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeading(title: "Today's food",
                              trailing: entries.isEmpty ? nil : "\(entries.count)")

            if entries.isEmpty {
                EmptyStateView(title: "Nothing logged yet",
                               message: "Add food by hand, photograph a meal, or scan a barcode.",
                               systemImage: "fork.knife",
                               actionTitle: "Add food") {
                    router.selectedTab = .addMeal
                }
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
                    .fill(AppTheme.color(for: nutrient).opacity(0.22))
                    .frame(width: max(0, width * (1 - fractions.start)))
                    .offset(x: width * fractions.start)

                Capsule()
                    .fill(AppTheme.color(for: state, nutrient: nutrient))
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
