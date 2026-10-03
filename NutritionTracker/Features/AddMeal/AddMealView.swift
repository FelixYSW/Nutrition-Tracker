import SwiftUI
import SwiftData

/// Add Meal holds one or more draft food cards before saving (spec section 12).
///
/// It always shows at least one card: the page opens with a blank one ready to
/// fill in, and the last card can't be removed. It is also the mandatory review
/// step for the photo pipeline, barcode scanning and the assistant, all of which
/// hand over drafts rather than writing to the database.
struct AddMealView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @State private var drafts: [FoodEntryDraft] = [FoodEntryDraft()]
    @State private var saveError: String?
    /// Explanation handed over with scanned or photographed drafts.
    @State private var notice: String?

    /// Default is now; changing it relabels the save button.
    private var isBackdated: Bool {
        guard let first = drafts.first else { return false }
        return !LocalDay.isToday(first.consumedAt)
    }

    private var combinedTotal: Nutrition {
        drafts.reduce(.zero) { $0 + $1.total }
    }

    private var canSave: Bool {
        drafts.allSatisfy(\.isSaveable)
    }

    /// One time for the whole meal, applied to every food on the page.
    private var mealTime: Binding<Date> {
        Binding(
            get: { drafts.first?.consumedAt ?? .now },
            set: { time in
                for index in drafts.indices { drafts[index].consumedAt = time }
            })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    if let notice {
                        noticeCard(notice)
                    } else if drafts.contains(where: { $0.source == .photoAI }) {
                        // The hand-over notice already says this, so only one shows.
                        EstimateDisclaimer().appCard()
                    }

                    ForEach($drafts) { $draft in
                        FoodDraftCard(draft: $draft,
                                      onDelete: deleteAction(for: draft.id))
                    }

                    Button {
                        addCard()
                    } label: {
                        Label("Add another food", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.appSecondary)

                    VStack(spacing: 14) {
                        DatePicker("Eaten at", selection: mealTime,
                                   in: ...Date.now.addingTimeInterval(60 * 60),
                                   displayedComponents: [.date, .hourAndMinute])
                            .font(.subheadline)

                        // A single food's card already shows its total.
                        if drafts.count > 1 {
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                AppSectionHeading(title: "Meal total",
                                                  trailing: "\(drafts.count) foods")
                                NutritionSummaryView(nutrition: combinedTotal, showsFibre: false)
                            }
                        }
                    }
                    .appCard()
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Add Meal")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { saveBar }
            .alert("Could not save",
                   isPresented: Binding(get: { saveError != nil },
                                        set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .onAppear(perform: collectPendingDrafts)
        .onChange(of: router.pendingDrafts.count) { _, _ in collectPendingDrafts() }
    }

    // MARK: Pieces

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
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .appCard()
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            Button {
                save()
            } label: {
                Text(isBackdated ? "Save to selected date" : "Save to today")
            }
            .buttonStyle(.appPrimary)
            .disabled(!canSave)

            if !canSave {
                Text("Give every food a name and some nutrition to save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.cardPadding + 4)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // Fade the page out under the button rather than a hard bar.
        .background(
            LinearGradient(colors: [AppTheme.background.opacity(0),
                                    AppTheme.background.opacity(0.95)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom))
    }

    // MARK: Actions

    /// Picks up drafts handed over by Scan or the assistant.
    private func collectPendingDrafts() {
        let pending = router.consumePendingDrafts()
        guard !pending.drafts.isEmpty else { return }

        if drafts.allSatisfy(\.isBlank) {
            // Replace the empty starter card rather than stacking above it.
            drafts = pending.drafts
        } else {
            // Join the meal already being built, at its time, newest first so
            // the card that was just filled in is at the top of the screen.
            let time = mealTime.wrappedValue
            drafts.insert(contentsOf: pending.drafts.map { draft in
                var draft = draft
                draft.consumedAt = time
                return draft
            }, at: 0)
        }
        notice = pending.notice
    }

    private func addCard() {
        // A new card joins the meal at the time already set.
        withAnimation(.snappy) {
            drafts.append(FoodEntryDraft(consumedAt: mealTime.wrappedValue))
        }
        Haptics.selection()
    }

    /// Nil hides "Remove food" when this is the only card left.
    private func deleteAction(for id: UUID) -> (() -> Void)? {
        guard drafts.count > 1 else { return nil }
        return { remove(id: id) }
    }

    private func remove(id: UUID) {
        // The page always keeps one card.
        guard drafts.count > 1 else { return }
        withAnimation(.snappy) { drafts.removeAll { $0.id == id } }
        Haptics.selection()
    }

    private func save() {
        guard canSave else { return }
        let keepCorrections = context.loadAppSettings().storeCorrectionsForTraining
        let encoder = JSONEncoder()
        for draft in drafts {
            context.insert(draft.makeEntry())

            // A barcode the database did not know about is cached with what the
            // user typed, so the next scan resolves locally (spec section 27).
            if draft.source == .barcode, let barcode = draft.barcode, !draft.isComposite,
               context.fetchCachedProduct(barcode: barcode) == nil {
                BarcodeLookupService(context: context).cache(
                    product: BarcodeProduct(barcode: barcode,
                                            name: draft.name,
                                            brand: nil,
                                            servingSize: draft.servingSize,
                                            unit: draft.unit,
                                            nutritionPerServing: draft.nutritionPerServing),
                    isUserEntered: true)
            }

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
        do {
            try context.save()
            drafts = [FoodEntryDraft()]
            notice = nil
            Haptics.success()
            router.selectedTab = .dashboard
        } catch {
            Haptics.error()
            saveError = error.localizedDescription
        }
    }
}

/// One editable food: simple, or composite with ingredient rows
/// (spec sections 10, 12).
///
/// Each fact appears once: the name, one amount control, one total line, then
/// the label values the total is worked out from.
struct FoodDraftCard: View {
    @Binding var draft: FoodEntryDraft
    /// Nil when the food can't be removed: it's the only card on the page, or
    /// a saved entry being edited.
    var onDelete: (() -> Void)?
    /// Add Meal sets one time for the whole meal; the edit sheet needs its own.
    var showsTimePicker: Bool = false

    @State private var showRemovePrompt = false
    @State private var expandedIngredient: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            amountRow
            NutritionSummaryView(nutrition: draft.total, showsFibre: false)

            Divider()

            // A composite food's nutrition comes from its ingredients, so it
            // has no label values of its own to edit.
            if draft.isComposite {
                ingredientsSection
            } else {
                NutritionEditor(nutrition: $draft.nutritionPerServing,
                                servingSize: $draft.servingSize,
                                unit: draft.unit,
                                showsExtendedFields: true)
            }

            if showsTimePicker {
                Divider()
                DatePicker("Eaten at", selection: $draft.consumedAt,
                           in: ...Date.now.addingTimeInterval(60 * 60),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline)
            }
        }
        .appCard()
        .alert("Remove \(draft.name.isEmpty ? "this food" : draft.name)?",
               isPresented: $showRemovePrompt) {
            Button("Remove", role: .destructive) { onDelete?() }
            Button("Keep", role: .cancel) { draft.quantity = draft.unit.step }
        } message: {
            Text("The amount reached zero.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Food name", text: $draft.name)
                    .font(.title3.weight(.semibold))
                    .textInputAutocapitalization(.words)

                // Only worth showing when it didn't come from typing it in.
                if draft.source != .manual || draft.hasLowConfidenceItems {
                    HStack(spacing: 6) {
                        Label(draft.source.displayName, systemImage: draft.source.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if draft.hasLowConfidenceItems {
                            ConfidenceBadge(confidence: draft.confidence
                                            ?? draft.ingredients.compactMap(\.confidence).min())
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Menu {
                if draft.isComposite {
                    Button("Add ingredient", systemImage: "plus") { addIngredient() }
                } else {
                    Button("Break into ingredients", systemImage: "list.bullet.indent") {
                        addIngredient()
                    }
                }
                if let onDelete {
                    Button("Remove food", systemImage: "trash", role: .destructive, action: onDelete)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: AppTheme.minimumTapTarget, height: AppTheme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Food options")
        }
    }

    /// The one place the amount eaten is set. A composite dish is counted in
    /// servings of the whole dish, so it has no unit choice.
    private var amountRow: some View {
        HStack(spacing: 8) {
            Text(draft.isComposite ? "Servings" : "Amount")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            QuantityStepper(quantity: $draft.quantity, unit: draft.unit) {
                if onDelete != nil {
                    showRemovePrompt = true
                } else {
                    // The only card can't be removed, so it can't reach zero either.
                    draft.quantity = draft.unit.step
                }
            }
            if !draft.isComposite {
                Picker("Unit", selection: $draft.unit) {
                    ForEach(ServingUnit.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ingredients")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach($draft.ingredients) { $ingredient in
                IngredientRow(
                    draft: $ingredient,
                    isExpanded: Binding(
                        get: { expandedIngredient == ingredient.id },
                        set: { expandedIngredient = $0 ? ingredient.id : nil }),
                    onDelete: { removeIngredient(id: ingredient.id) })
            }

            Button {
                addIngredient()
            } label: {
                Label("Add ingredient", systemImage: "plus")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
        }
    }

    // MARK: Actions

    private func addIngredient() {
        withAnimation(.snappy) {
            // Turning a simple food into a composite one carries its values into
            // the first ingredient, so nothing already typed is lost.
            if draft.ingredients.isEmpty, draft.nutritionPerServing != .zero {
                draft.ingredients.append(IngredientDraft(
                    name: draft.name.isEmpty ? "Ingredient 1" : draft.name,
                    quantity: draft.quantity,
                    servingSize: draft.servingSize,
                    unit: draft.unit,
                    nutritionPerServing: draft.nutritionPerServing))
                draft.nutritionPerServing = .zero
                draft.quantity = 1
                draft.servingSize = 1
                draft.unit = .serving
            }
            let added = IngredientDraft(name: "", quantity: 100, servingSize: 100, unit: .gram)
            draft.ingredients.append(added)
            // Open the new one so its values can be typed straight away.
            expandedIngredient = added.id
        }
        Haptics.selection()
    }

    private func removeIngredient(id: UUID) {
        withAnimation(.snappy) {
            draft.ingredients.removeAll { $0.id == id }
        }
        Haptics.selection()
    }
}
