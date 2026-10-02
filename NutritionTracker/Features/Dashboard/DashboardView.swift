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
    @State private var isShowingAssistant = false
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
                    ringsCard
                    fibreCard
                    statusMessages
                    entriesSection
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable {
                // Pull-to-refresh re-checks the local day, which also covers
                // returning to the app after midnight.
                dayObserver.refresh()
            }
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
            .sheet(isPresented: $isShowingAssistant) { AssistantView() }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                isShowingAssistant = true
            } label: {
                Image(systemName: "sparkles")
                    .accessibilityLabel(assistantIsReady
                        ? "Open assistant"
                        : "Assistant not available")
            }
            // Never a dead tap target: when unavailable it still opens and says
            // so (spec section 29A).
            .opacity(assistantIsReady ? 1 : 0.5)

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .accessibilityLabel("Settings")
            }
        }
    }

    private var assistantIsReady: Bool { BundledAPIKey.hasAssistantKey }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppFormatters.dayTitle.string(from: today).uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.accent)
            Text("\(AppFormatters.amount(consumed.calories)) kcal so far")
                .font(.largeTitle.bold())
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ringsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Adaptive grid: four rings across on a Pro Max, two on an SE,
            // never a fixed four-column row that squashes.
            let columns = [GridItem(.adaptive(minimum: 78, maximum: 150), spacing: 14)]
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Nutrient.allCases.filter(\.isPrimary)) { nutrient in
                    CircularNutritionProgress(nutrient: nutrient,
                                              consumed: consumed[nutrient],
                                              range: ranges[nutrient])
                }
            }

            if ranges.calories.max <= 0 {
                Text("No targets yet. Set them in Settings under Daily Targets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .appCard()
    }

    private var fibreCard: some View {
        // Fibre is secondary: a bar rather than a ring, so it does not compete
        // with the four primary nutrients.
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fibre").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(AppFormatters.amount(consumed.fibre)) of \(AppFormatters.range(ranges.fibre)) g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            RangeBar(consumed: consumed.fibre, range: ranges.fibre, nutrient: .fibre)
        }
        .appCard()
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
                    FoodDraftCard(draft: $draft, onDelete: nil)
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
