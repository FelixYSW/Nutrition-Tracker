import SwiftUI
import SwiftData

/// Add Meal holds one or more draft food cards before saving (spec section 12).
///
/// This is also the mandatory review step for the photo pipeline, barcode
/// scanning and the assistant: all of them hand over drafts rather than writing
/// to the database.
struct AddMealView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @State private var drafts: [FoodEntryDraft] = []
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
        !drafts.isEmpty && drafts.allSatisfy(\.isSaveable)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    if let notice {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(AppTheme.accent)
                                .accessibilityHidden(true)
                            Text(notice)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button {
                                withAnimation(.snappy) { self.notice = nil }
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

                    if drafts.contains(where: { $0.source == .photoAI }) {
                        EstimateDisclaimer()
                            .appCard()
                    }

                    if drafts.isEmpty {
                        EmptyStateView(
                            title: "No food added yet",
                            message: "Add a food card to enter something by hand, or use "
                                + "the Scan tab to photograph a meal or scan a barcode.",
                            systemImage: "plus.circle",
                            actionTitle: "Add food card") {
                            addCard()
                        }
                        .appCard()
                    } else {
                        ForEach($drafts) { $draft in
                            FoodDraftCard(draft: $draft) {
                                remove(id: draft.id)
                            }
                        }

                        Button {
                            addCard()
                        } label: {
                            Label("Add another food", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        totalsCard
                    }
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Add Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addCard()
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("Add food card")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !drafts.isEmpty { saveBar }
            }
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

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeading(title: "Total",
                              trailing: "\(drafts.count) item\(drafts.count == 1 ? "" : "s")")
            NutritionSummaryView(nutrition: combinedTotal)
        }
        .appCard()
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            Button {
                save()
            } label: {
                Text(isBackdated ? "SAVE TO SELECTED DATE" : "ADD TO TODAY")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)

            if !canSave {
                Text("Give every food a name and some nutrition to save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Actions

    /// Picks up drafts handed over by Scan or the assistant.
    private func collectPendingDrafts() {
        let pending = router.consumePendingDrafts()
        guard !pending.drafts.isEmpty else { return }
        // Newest first, so the card that was just filled in is at the top of the
        // screen rather than below any foods already waiting to be saved.
        drafts.insert(contentsOf: pending.drafts, at: 0)
        notice = pending.notice
    }

    private func addCard() {
        // A new card inherits the timestamp already in use, so a backdated meal
        // does not need the date re-set for every food.
        let timestamp = drafts.first?.consumedAt ?? .now
        drafts.append(FoodEntryDraft(consumedAt: timestamp))
        Haptics.selection()
    }

    private func remove(id: UUID) {
        drafts.removeAll { $0.id == id }
        if drafts.isEmpty { notice = nil }
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
            drafts = []
            notice = nil
            Haptics.success()
            router.selectedTab = .dashboard
        } catch {
            Haptics.error()
            saveError = error.localizedDescription
        }
    }
}

/// One editable food card: simple or composite, with nested ingredient cards
/// (spec sections 10, 12).
struct FoodDraftCard: View {
    @Binding var draft: FoodEntryDraft
    /// Nil hides the delete control, e.g. when editing a single saved entry.
    var onDelete: (() -> Void)?

    @State private var isEditingDetails = false
    @State private var showRemovePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(spacing: 10) {
                QuantityStepper(quantity: $draft.quantity, unit: draft.unit) {
                    showRemovePrompt = true
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(AppFormatters.amount(draft.total.calories)) kcal")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(draft.isComposite ? "from ingredients" : "total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            NutritionSummaryView(nutrition: draft.total, showsFibre: false)

            Divider()

            // A composite food derives its nutrition from children, so the
            // parent's own nutrition editor is hidden to avoid implying it is
            // used (which it is not - see FoodEntryDraft.nutritionForOneServing).
            if draft.isComposite {
                ingredientsSection
            } else {
                simpleFoodSection
                Button {
                    withAnimation(.snappy) { addIngredient() }
                } label: {
                    Label("Break into ingredients", systemImage: "list.bullet.indent")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
            }

            Divider()

            DatePicker("Eaten at", selection: $draft.consumedAt,
                       in: ...Date.now.addingTimeInterval(60 * 60),
                       displayedComponents: [.date, .hourAndMinute])
                .font(.subheadline)
        }
        .appCard()
        .alert("Remove \(draft.name.isEmpty ? "this food" : draft.name)?",
               isPresented: $showRemovePrompt) {
            Button("Remove", role: .destructive) { onDelete?() }
            Button("Keep", role: .cancel) {
                draft.quantity = draft.unit.step
            }
        } message: {
            Text("The quantity reached zero.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Food name", text: $draft.name)
                    .font(.headline)
                    .textInputAutocapitalization(.words)
                HStack(spacing: 6) {
                    Image(systemName: draft.source.symbolName)
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(draft.source.displayName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if draft.hasLowConfidenceItems {
                ConfidenceBadge(confidence: draft.confidence
                                ?? draft.ingredients.compactMap(\.confidence).min())
            }

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .accessibilityLabel("Delete this food")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var simpleFoodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Unit").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("Unit", selection: $draft.unit) {
                    ForEach(ServingUnit.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            NutritionEditor(nutrition: $draft.nutritionPerServing,
                            servingSize: $draft.servingSize,
                            unit: draft.unit,
                            showsExtendedFields: true)
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeading(title: "Ingredients",
                              trailing: "\(draft.ingredients.count)")

            ForEach($draft.ingredients) { $ingredient in
                IngredientCard(draft: $ingredient) {
                    withAnimation(.snappy) {
                        draft.ingredients.removeAll { $0.id == ingredient.id }
                    }
                }
            }

            Button {
                withAnimation(.snappy) { addIngredient() }
            } label: {
                Label("Add ingredient", systemImage: "plus.circle")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)

            Text("The parent total is worked out from the ingredients. "
                 + "Changing the food's quantity scales them all.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addIngredient() {
        // Moving a simple food to composite carries its existing nutrition into
        // the first ingredient, so nothing the user typed is lost.
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
        } else {
            draft.ingredients.append(IngredientDraft(
                name: "", quantity: 100, servingSize: 100, unit: .gram))
        }
        Haptics.selection()
    }
}
