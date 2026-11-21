import SwiftUI
import SwiftData

/// The Foods tab: the page around the list of foods eaten before.
struct FoodsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    PageHeader(title: "Foods")
                    FoodDatabaseView()
                }
                .appPageContent()
            }
            .appPageSurface()
            // The title is drawn in the page, like every tab.
            .toolbar(.hidden, for: .navigationBar)
            .keyboardDismissControls()
        }
    }
}

/// Every food the user has logged before, searchable, with its figures and
/// history, and a one-tap way to log it again. Built from the food log; there
/// is no second copy to keep in step.
struct FoodDatabaseView: View {
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var entries: [FoodEntry]

    @State private var ownQuery = ""
    @State private var order: FoodLibrarySort = .recent
    @State private var selected: FoodRecord?
    /// The list on screen, built only when the log, the search or the sort
    /// changes - not on every redraw: grouping and sorting every food ever
    /// logged was slow enough to stall sheets closing on this page.
    private struct ListKey: Equatable {
        let log: Int
        let query: String
        let order: FoodLibrarySort
    }
    @State private var cachedList: [FoodRecord] = []
    @State private var cachedKey: ListKey?
    @State private var allRecords: [FoodRecord] = []
    @State private var allRecordsLog: Int?

    private var query: String { ownQuery }

    private var listKey: ListKey {
        ListKey(log: FoodLibrary.signature(of: entries), query: query, order: order)
    }

    private var records: [FoodRecord] {
        let key = listKey
        if key == cachedKey { return cachedList }
        return build(for: key)
    }

    /// Groups the log (only when it changed), then filters and sorts.
    private func build(for key: ListKey) -> [FoodRecord] {
        let grouped = key.log == allRecordsLog ? allRecords : FoodLibrary.records(from: entries)
        return FoodLibrary.sorted(FoodLibrary.filter(grouped, query: key.query), by: key.order)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            searchField

            Picker("Sort", selection: $order) {
                ForEach(FoodLibrarySort.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            let found = records
            if entries.isEmpty {
                EmptyStateView(title: "No foods yet",
                               message: "Foods you log will collect here, so you can check "
                                   + "them again or log them in one tap.",
                               systemImage: "fork.knife")
                    .appCard()
            } else if found.isEmpty {
                EmptyStateView(title: "No match",
                               message: "Nothing you've logged matches \"\(query)\".",
                               systemImage: "magnifyingglass")
                    .appCard()
            } else {
                AppSectionHeading(title: "Your foods", trailing: "\(found.count)")
                // Only the rows on screen are built.
                LazyVStack(spacing: AppTheme.pageSpacing) {
                    ForEach(found) { record in
                        Button {
                            selected = record
                        } label: { row(record) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: listKey, initial: true) { _, key in
            if key.log != allRecordsLog {
                allRecords = FoodLibrary.records(from: entries)
                allRecordsLog = key.log
            }
            cachedList = FoodLibrary.sorted(FoodLibrary.filter(allRecords, query: key.query),
                                            by: key.order)
            cachedKey = key
        }
        .sheet(item: $selected) { record in
            FoodRecordSheet(record: record)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your foods", text: $ownQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !ownQuery.isEmpty {
                Button { ownQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: AppTheme.minimumTapTarget)
        .background(AppTheme.cardBackground, in: Capsule())
    }

    private func row(_ record: FoodRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text("Logged \(record.timesLogged)\u{00D7} \u{00B7} last "
                     + AppFormatters.dayAndMonth.string(from: record.lastEaten))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(AppFormatters.amount(record.latestTotal.calories))")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                Text("kcal").font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.minimumTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .appCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows details and lets you log it again")
    }
}

/// One food's details: what it came to, what's in it, when it was eaten, and
/// buttons to log it again.
struct FoodRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let record: FoodRecord
    @State private var servings: Double = 1
    @State private var justLogged = false
    /// Picked only for a past meal; otherwise it's logged at the moment of
    /// tapping Log.
    @State private var eatenAt: Date?

    private var entry: FoodEntry { record.latest }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.name)
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                        Text("Last time: \(AppFormatters.quantity(entry.quantity, unit: entry.unit)) "
                             + "\(entry.unit.shortLabel) \u{00B7} "
                             + "\(AppFormatters.dayTitle.string(from: entry.consumedAt))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NutritionSummaryView(nutrition: record.latestTotal)
                        if record.timesLogged > 1 {
                            Text("Averages \(AppFormatters.amount(record.averageCalories)) kcal "
                                 + "over \(record.timesLogged) times.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appCard()

                    if entry.isComposite { ingredientsCard }

                    historyCard

                    logAgainCard
                }
                .appPageContent()
            }
            .appPageSurface()
            .onChange(of: eatenAt) { _, _ in justLogged = false }
            .onChange(of: servings) { _, _ in justLogged = false }
            .navigationTitle("Food details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var ingredientsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionHeading(title: "What's in it")
            ForEach(entry.orderedIngredients) { item in
                HStack {
                    Text(item.name).font(.subheadline)
                    Spacer()
                    Text("\(AppFormatters.quantity(item.quantity, unit: item.unit)) "
                         + "\(item.unit.shortLabel) \u{00B7} "
                         + "\(AppFormatters.amount(item.total.calories)) kcal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionHeading(title: "History", trailing: "\(record.timesLogged)\u{00D7}")
            ForEach(record.entries.prefix(8)) { past in
                HStack {
                    Text(AppFormatters.dayTitle.string(from: past.consumedAt))
                        .font(.subheadline)
                    Spacer()
                    Text("\(AppFormatters.amount(past.total.calories)) kcal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if record.entries.count > 8 {
                Text("and \(record.entries.count - 8) earlier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var logAgainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $servings, in: 0.5...10, step: 0.5) {
                Text("Portion: \(servings == servings.rounded() ? String(Int(servings)) : String(servings))\u{00D7} last time")
                    .font(.subheadline.weight(.semibold))
            }
            EatenAtRow(time: $eatenAt)
            Button {
                logAgain()
            } label: {
                Label(justLogged ? "Logged" : "Log again",
                      systemImage: justLogged ? "checkmark" : "plus")
            }
            .buttonStyle(.appPrimary)
            .disabled(justLogged)
        }
        .appCard()
    }

    /// A copy of the entry at the current time, scaled by the chosen portion.
    /// The ingredients and figures are copied exactly as they were saved.
    private func logAgain() {
        var draft = FoodEntryDraft(entry: entry).repeated(at: eatenAt ?? .now, servings: servings)
        // A copy of a food, not something the assistant did.
        draft.source = entry.source
        context.insert(draft.makeEntry())
        try? context.save()
        Haptics.success()
        justLogged = true
    }
}

/// "Eaten: Now" until a time is picked; then the picked date and time, with a
/// Now button to go back. Used wherever a food can be logged for the past.
struct EatenAtRow: View {
    @Binding var time: Date?

    var body: some View {
        HStack(spacing: 8) {
            DatePicker("Eaten", selection: Binding(get: { time ?? .now }, set: { time = $0 }),
                       in: ...Date.now.addingTimeInterval(60 * 60),
                       displayedComponents: [.date, .hourAndMinute])
                .font(.subheadline.weight(.semibold))
            if time != nil {
                Button("Now") {
                    time = nil
                    Haptics.selection()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .frame(minWidth: AppTheme.minimumTapTarget, minHeight: AppTheme.minimumTapTarget)
                .accessibilityHint("Logs it at the current time instead")
            }
        }
    }
}
