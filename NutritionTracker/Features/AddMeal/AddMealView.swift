import SwiftUI
import SwiftData

/// Add food (spec section 12), built around the quickest way to log:
///
/// 1. Search what you've eaten before and add it in a tap, choosing how much.
/// 2. Or hand it to the assistant: a photo (it uses your fist for scale) or
///    a description.
/// 3. Or type a new food's figures from its label.
///
/// Everything added collects in "This meal" and is saved together at one
/// time. It is still the review step for drafts handed over by the
/// assistant, which never write to the database themselves.
struct AddMealView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \FoodEntry.consumedAt, order: .reverse) private var entries: [FoodEntry]

    @State private var meal: [FoodEntryDraft] = []
    /// Set only when the user picks a time; otherwise the meal is "now" at
    /// the moment it's logged, however long the tab has been open.
    @State private var chosenTime: Date?
    private var mealTime: Date { chosenTime ?? .now }
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @State private var choosingAmount: FoodRecord?
    @State private var editing: MealItemTarget?
    @State private var saveError: String?
    /// Explanation handed over with drafts from elsewhere in the app.
    @State private var notice: String?

    /// How many foods "Recent" shows before the search is the better tool.
    private static let recentCount = 10

    /// Rebuilt only when the log changes (see FoodLibrary.signature).
    @State private var cachedRecords: [FoodRecord] = []
    @State private var cachedRecordsLog: Int?
    private var records: [FoodRecord] {
        // Until the cache is filled (the first frame), build them directly.
        cachedRecordsLog == FoodLibrary.signature(of: entries)
            ? cachedRecords : FoodLibrary.records(from: entries)
    }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var mealTotal: Nutrition { meal.reduce(.zero) { $0 + $1.total } }
    private var canSave: Bool { !meal.isEmpty && meal.allSatisfy(\.isSaveable) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    PageHeader(title: "Add food")

                    if let notice { noticeCard(notice) }

                    searchField

                    if !meal.isEmpty { mealSection }

                    if trimmedQuery.isEmpty {
                        quickActions
                        recentSection
                    } else {
                        resultsSection
                    }
                }
                .appPageContent()
            }
            .appPageSurface()
            // The title is drawn in the page, like every tab.
            .toolbar(.hidden, for: .navigationBar)
            .keyboardDismissControls()
            .safeAreaInset(edge: .bottom) {
                if !meal.isEmpty { saveBar }
            }
            .sheet(item: $choosingAmount) { record in
                HowMuchSheet(record: record) { servings in
                    add(record, servings: servings)
                }
            }
            .sheet(item: $editing) { target in
                MealItemEditor(draft: target.draft, isNew: target.isNew,
                               onDone: { draft in commit(draft, for: target) },
                               onRemove: target.isNew ? nil : { remove(id: target.draft.id) })
            }
            .alert("Could not save",
                   isPresented: Binding(get: { saveError != nil },
                                        set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .onChange(of: FoodLibrary.signature(of: entries), initial: true) { _, log in
            cachedRecords = FoodLibrary.records(from: entries)
            cachedRecordsLog = log
        }
        .onAppear(perform: collectPendingDrafts)
        .onChange(of: router.pendingDrafts.count) { _, _ in collectPendingDrafts() }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("What did you eat?", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: AppTheme.minimumTapTarget, height: AppTheme.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: 50)
        .background(AppTheme.cardBackground, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.cardBorder, lineWidth: 1))
    }

    // MARK: Ways to add

    private var quickActions: some View {
        HStack(spacing: 10) {
            actionTile("Photo", systemImage: "camera",
                       hint: "Opens the assistant's camera") {
                router.openAssistant(.photo)
            }
            actionTile("Describe", systemImage: "text.bubble",
                       hint: "Tell the assistant what you ate") {
                router.openAssistant(.describe)
            }
            actionTile("New food", systemImage: "square.and.pencil",
                       hint: "Type in a food's figures from its label") {
                editing = MealItemTarget(draft: FoodEntryDraft(consumedAt: mealTime), isNew: true)
            }
        }
    }

    private func actionTile(_ title: String, systemImage: String, hint: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(AppTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.cardBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    // MARK: Lists of foods

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let recent = Array(FoodLibrary.sorted(records, by: .recent).prefix(Self.recentCount))
            if recent.isEmpty {
                EmptyStateView(title: "Nothing logged yet",
                               message: "Use Photo or Describe and the assistant works it out, "
                                   + "or New food to type in a label. Foods you log show up "
                                   + "here to add again in one tap.",
                               systemImage: "fork.knife")
                    .appCard()
            } else {
                AppSectionHeading(title: "Recent")
                ForEach(recent) { record in foodRow(record) }
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let found = Array(FoodLibrary.sorted(FoodLibrary.filter(records, query: trimmedQuery),
                                                 by: .mostLogged).prefix(20))
            if !found.isEmpty {
                AppSectionHeading(title: "Your foods", trailing: "\(found.count)")
                ForEach(found) { record in foodRow(record) }
            }
            // Always offered, so a food never seen before is one tap away.
            Button {
                var draft = FoodEntryDraft(consumedAt: mealTime)
                draft.name = trimmedQuery.prefix(1).uppercased() + trimmedQuery.dropFirst()
                editing = MealItemTarget(draft: draft, isNew: true)
            } label: {
                Label("New food \u{201C}\(trimmedQuery)\u{201D}", systemImage: "plus.circle.fill")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: AppTheme.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appCard()

            if found.isEmpty {
                Text("Not something you've logged before. Type its figures in, or let the "
                     + "assistant work it out with Photo or Describe.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Tap for "how much?"; + adds the same as last time straight away.
    private func foodRow(_ record: FoodRecord) -> some View {
        HStack(spacing: 8) {
            Button {
                choosingAmount = record
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.name)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Text(Self.amountText(record.latest) + " \u{00B7} "
                             + AppFormatters.amount(record.latestTotal.calories) + " kcal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .frame(minHeight: AppTheme.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose how much, then add it to this meal")

            Button {
                add(record, servings: 1)
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .foregroundStyle(AppTheme.onAccent)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.accentFill, in: Circle())
                    .frame(width: AppTheme.minimumTapTarget, height: AppTheme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(record.name), same as last time")
        }
        .appCard()
    }

    // MARK: This meal

    private var mealSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            AppSectionHeading(title: "This meal",
                              trailing: "\(AppFormatters.amount(mealTotal.calories)) kcal")
                .padding(.bottom, 6)
            ForEach(meal) { draft in
                HStack(spacing: 8) {
                    Button {
                        editing = MealItemTarget(draft: draft, isNew: false)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.name.isEmpty ? "Unnamed food" : draft.name)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                Text("\(AppFormatters.quantity(draft.quantity, unit: draft.unit)) "
                                     + draft.unit.shortLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text("\(AppFormatters.amount(draft.total.calories)) kcal")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(minHeight: AppTheme.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit this food")

                    Button {
                        remove(id: draft.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: AppTheme.minimumTapTarget, height: AppTheme.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(draft.name) from this meal")
                }
                if draft.id != meal.last?.id { Divider() }
            }
            if meal.count > 1 {
                NutritionSummaryView(nutrition: mealTotal)
                    .padding(.top, 8)
            }
            Divider().padding(.vertical, 6)
            // Now unless a time is picked - for logging a meal from earlier.
            EatenAtRow(time: $chosenTime)
        }
        .appSkyCard()
    }

    /// One button, in thumb reach. The time is set in "This meal".
    private var saveBar: some View {
        Button {
            save()
        } label: {
            Text("Log \(meal.count == 1 ? "food" : "\(meal.count) foods") \u{00B7} "
                 + "\(AppFormatters.amount(mealTotal.calories)) kcal")
        }
        .buttonStyle(.appPrimary)
        .disabled(!canSave)
        .padding(.horizontal, AppTheme.cardPadding + 4)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
        .overlay(alignment: .top) { Divider() }
    }

    private func noticeCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                withAnimation(.snappy) { notice = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .appCard()
    }

    static func amountText(_ entry: FoodEntry) -> String {
        "\(AppFormatters.quantity(entry.quantity, unit: entry.unit)) \(entry.unit.shortLabel)"
    }

    // MARK: Actions

    /// A copy of the food as it was last logged, scaled by `servings`.
    private func add(_ record: FoodRecord, servings: Double) {
        var draft = FoodEntryDraft(entry: record.latest).repeated(at: mealTime, servings: servings)
        draft.source = record.latest.source
        withAnimation(.snappy) { meal.append(draft) }
        query = ""
        isSearchFocused = false
        Haptics.selection()
    }

    private func commit(_ draft: FoodEntryDraft, for target: MealItemTarget) {
        withAnimation(.snappy) {
            if let index = meal.firstIndex(where: { $0.id == target.draft.id }) {
                meal[index] = draft
            } else {
                meal.append(draft)
            }
        }
        query = ""
    }

    private func remove(id: UUID) {
        withAnimation(.snappy) { meal.removeAll { $0.id == id } }
        if meal.isEmpty { chosenTime = nil }
        Haptics.selection()
    }

    /// Drafts handed over from elsewhere join this meal.
    private func collectPendingDrafts() {
        let pending = router.consumePendingDrafts()
        guard !pending.drafts.isEmpty else { return }
        if meal.isEmpty, let first = pending.drafts.first,
           abs(first.consumedAt.timeIntervalSinceNow) > 5 * 60 {
            chosenTime = first.consumedAt
        }
        withAnimation(.snappy) { meal.append(contentsOf: pending.drafts) }
        notice = pending.notice
    }

    private func save() {
        guard canSave else { return }
        let keepCorrections = context.loadAppSettings().storeCorrectionsForTraining
        let encoder = JSONEncoder()
        for var draft in meal {
            draft.consumedAt = mealTime
            context.insert(draft.makeEntry())
            // Pair what the models predicted with what the user confirmed, if
            // they opted in. Stays on-device (spec section 24).
            if keepCorrections,
               let predictionJSON = draft.predictionJSON,
               let correctionJSON = try? encoder.encode(draft) {
                context.insert(CorrectionRecord(predictionJSON: predictionJSON,
                                                correctionJSON: correctionJSON,
                                                photoPath: draft.photoPath))
            }
        }
        let loggedFor = mealTime
        do {
            try context.save()
            meal = []
            chosenTime = nil
            notice = nil
            Haptics.success()
            // Today opens on the day it was logged for, so a past meal shows.
            router.todayPickedDay = LocalDay.isToday(loggedFor) ? nil : LocalDay.start(of: loggedFor)
            router.selectedTab = .dashboard
        } catch {
            Haptics.error()
            saveError = error.localizedDescription
        }
    }
}

/// A food in, or about to join, the meal being edited in a sheet.
struct MealItemTarget: Identifiable {
    var id: UUID { draft.id }
    var draft: FoodEntryDraft
    let isNew: Bool
}

// MARK: - How much?

/// After picking a food: how much of it, against what was eaten last time.
struct HowMuchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let record: FoodRecord
    let onAdd: (Double) -> Void

    @State private var servings: Double = 1
    private struct Preset: Identifiable {
        let label: String
        let value: Double
        var id: Double { value }
    }
    private static let presets = [Preset(label: "\u{00BD}\u{00D7}", value: 0.5),
                                  Preset(label: "1\u{00D7}", value: 1),
                                  Preset(label: "1\u{00BD}\u{00D7}", value: 1.5),
                                  Preset(label: "2\u{00D7}", value: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.name)
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("Last time: \(AddMealView.amountText(record.latest)) \u{00B7} "
                             + "\(AppFormatters.amount(record.latestTotal.calories)) kcal")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        ForEach(Self.presets) { preset in
                            Button {
                                servings = preset.value
                                Haptics.selection()
                            } label: {
                                Text(preset.label)
                                    .font(.system(.body, design: .rounded).weight(.bold))
                                    .foregroundStyle(servings == preset.value ? AppTheme.onAccent : AppTheme.ink)
                                    .frame(maxWidth: .infinity, minHeight: AppTheme.minimumTapTarget)
                                    .background(servings == preset.value ? AppTheme.accentFill : AppTheme.subtleFill,
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(preset.value.formatted()) times last time")
                            .accessibilityAddTraits(servings == preset.value ? .isSelected : [])
                        }
                    }

                    Stepper(value: $servings, in: 0.25...10, step: 0.25) {
                        Text("\(servings.formatted()) \u{00D7} last time")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }

                    NutritionSummaryView(nutrition: record.latestTotal * servings)

                    Button("Add to meal") {
                        onAdd(servings)
                        dismiss()
                    }
                    .buttonStyle(.appPrimary)
                }
                .padding(AppTheme.cardPadding + 4)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("How much?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Edit or create one food

/// The full editor for one food in the meal: a new food typed from its
/// label, or one already added that needs a change.
struct MealItemEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: FoodEntryDraft
    let isNew: Bool
    let onDone: (FoodEntryDraft) -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        NavigationStack {
            FoodEditor(draft: $draft,
                       removeTitle: onRemove == nil ? nil : "Remove from meal",
                       onRemove: onRemove.map { remove -> () -> Void in
                           { remove(); dismiss() }
                       })
            .keyboardDismissControls()
            .navigationTitle(isNew ? "New food" : "Edit food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Done") {
                        onDone(draft)
                        dismiss()
                    }
                    .disabled(!draft.isSaveable)
                }
            }
        }
    }
}
