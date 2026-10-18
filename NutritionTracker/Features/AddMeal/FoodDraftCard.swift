import SwiftUI

/// One editable food: simple, or composite with ingredient rows
/// (spec sections 10, 12).
///
/// The card shows only what a person checks at a glance - the name, how much,
/// and the macros it adds up to. The label values behind those macros, and
/// each ingredient's details, open in a sheet instead of filling the page
/// with input boxes.
struct FoodDraftCard: View {
    @Binding var draft: FoodEntryDraft
    /// Nil when the food can't be removed: it's the only card on the page, or
    /// a saved entry being edited.
    var onDelete: (() -> Void)?
    /// Add Meal sets one time for the whole meal; the edit sheet needs its own.
    var showsTimePicker: Bool = false

    @State private var showRemovePrompt = false
    @State private var isEditingNutrition = false
    @State private var editingIngredient: IngredientSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            amountRow
            NutritionSummaryView(nutrition: draft.total)

            if draft.isComposite {
                ingredientsSection
            } else {
                nutritionButton
            }

            if showsTimePicker {
                Divider()
                DatePicker("Eaten at", selection: $draft.consumedAt,
                           in: ...Date.now.addingTimeInterval(60 * 60),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline.weight(.semibold))
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
        .sheet(isPresented: $isEditingNutrition) {
            NutritionSheet(name: draft.name,
                           nutrition: $draft.nutritionPerServing,
                           servingSize: $draft.servingSize,
                           unit: $draft.unit)
        }
        .sheet(item: $editingIngredient, onDismiss: dropEmptyIngredients) { selection in
            if let binding = ingredientBinding(id: selection.id) {
                IngredientSheet(ingredient: binding, isNew: selection.isNew) {
                    removeIngredient(id: selection.id)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Food")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                TextField("What did you eat?", text: $draft.name, axis: .vertical)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .textInputAutocapitalization(.words)
                    .lineLimit(1...3)

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

            // A composite food's calories come from its ingredients; say so
            // beside the name, as in the mockup.
            if draft.isComposite {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(AppFormatters.amount(draft.total.calories))
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                            .monospacedDigit()
                        Text("kcal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("from ingredients")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            optionsMenu
        }
    }

    private var optionsMenu: some View {
        Menu {
            if draft.isComposite {
                Button("Add ingredient", systemImage: "plus") { addIngredient() }
            } else {
                Button("Edit nutrition", systemImage: "slider.horizontal.3") {
                    isEditingNutrition = true
                }
                Button("Break into ingredients", systemImage: "list.bullet.indent") {
                    addIngredient()
                }
            }
            if let onDelete {
                Button("Remove food", systemImage: "trash", role: .destructive, action: onDelete)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: AppTheme.minimumTapTarget, height: AppTheme.minimumTapTarget)
                .overlay(Circle().stroke(AppTheme.cardBorder, lineWidth: 1))
                .contentShape(Circle())
        }
        .accessibilityLabel("Food options")
    }

    // MARK: Amount

    /// The one place the amount eaten is set. A composite dish is counted in
    /// servings of the whole dish, so it has no unit choice.
    private var amountRow: some View {
        HStack(spacing: 8) {
            Text(draft.isComposite ? "Servings" : "Amount")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
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
                UnitPicker(unit: $draft.unit)
            }
        }
    }

    // MARK: Simple food

    /// One row in place of the old grid of label boxes. Prominent while the
    /// food has no nutrition yet, since that's what it still needs.
    private var nutritionButton: some View {
        let isEmpty = draft.nutritionPerServing == .zero
        return Button {
            isEditingNutrition = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isEmpty ? "plus.circle.fill" : "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isEmpty ? "Add nutrition" : "Edit nutrition")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                    Text(isEmpty
                         ? "Type it in from the label or packet"
                         : "Per \(AppFormatters.quantity(draft.servingSize, unit: draft.unit)) "
                            + draft.unit.shortLabel + " \u{00B7} from "
                            + draft.provenanceSummary)
                        .font(.caption)
                        .foregroundStyle(isEmpty ? AppTheme.onAccent.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isEmpty ? AppTheme.onAccent : AppTheme.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(isEmpty ? AppTheme.accentFill : AppTheme.subtleFill.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Composite food

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ingredients")
                .font(.system(.subheadline, design: .rounded).weight(.bold))

            ForEach($draft.ingredients) { $ingredient in
                IngredientSummaryRow(ingredient: $ingredient,
                                     onOpen: { editingIngredient = IngredientSelection(id: ingredient.id) },
                                     onReachedZero: { removeIngredient(id: ingredient.id) })
            }

            DashedAddButton(title: "Add ingredient") { addIngredient() }
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
            // Open it straight away so its name and values can be typed in.
            editingIngredient = IngredientSelection(id: added.id, isNew: true)
        }
        Haptics.selection()
    }

    private func removeIngredient(id: UUID) {
        withAnimation(.snappy) {
            draft.ingredients.removeAll { $0.id == id }
        }
        Haptics.selection()
    }

    /// A new ingredient closed without anything typed in isn't kept.
    private func dropEmptyIngredients() {
        draft.ingredients.removeAll {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.nutritionPerServing == .zero
        }
    }

    private func ingredientBinding(id: UUID) -> Binding<IngredientDraft>? {
        guard draft.ingredients.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.ingredients.first { $0.id == id } ?? IngredientDraft() },
            set: { newValue in
                if let index = draft.ingredients.firstIndex(where: { $0.id == id }) {
                    draft.ingredients[index] = newValue
                }
            })
    }
}

/// Which ingredient's sheet is open.
private struct IngredientSelection: Identifiable {
    let id: UUID
    var isNew = false
}

private extension FoodEntryDraft {
    /// Where the label values came from, for the "Edit nutrition" row.
    var provenanceSummary: String {
        switch source {
        case .manual: "you"
        default: source.displayName.lowercased()
        }
    }
}

// MARK: - Ingredient row

/// One ingredient as a single line: name (tap to edit), amount stepper and
/// its calories - the mockup's layout. The details open in a sheet.
struct IngredientSummaryRow: View {
    @Binding var ingredient: IngredientDraft
    let onOpen: () -> Void
    let onReachedZero: () -> Void

    @State private var showRemovePrompt = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ingredient.name.isEmpty ? "Unnamed" : ingredient.name)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(ingredient.name.isEmpty ? Color.secondary : AppTheme.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if ingredient.isLowConfidence {
                            ConfidenceBadge(confidence: ingredient.confidence)
                        }
                    }
                    Text("\(AppFormatters.amount(ingredient.total.calories)) kcal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, minHeight: AppTheme.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit this ingredient")

            QuantityStepper(quantity: $ingredient.quantity, unit: ingredient.unit) {
                showRemovePrompt = true
            }
            Text(ingredient.unit.shortLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(AppTheme.subtleFill.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .alert("Remove \(ingredient.name.isEmpty ? "this ingredient" : ingredient.name)?",
               isPresented: $showRemovePrompt) {
            Button("Remove", role: .destructive, action: onReachedZero)
            Button("Keep", role: .cancel) { ingredient.quantity = ingredient.unit.step }
        } message: {
            Text("The amount reached zero.")
        }
    }
}

// MARK: - Sheets

/// Label values for a simple food, in their own sheet.
struct NutritionSheet: View {
    let name: String
    @Binding var nutrition: Nutrition
    @Binding var servingSize: Double
    @Binding var unit: ServingUnit

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    Text("Copy the values from the label or packet. The macros on "
                         + "the card are worked out from these and the amount you ate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Unit")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            UnitPicker(unit: $unit)
                        }
                        NutritionEditor(nutrition: $nutrition,
                                        servingSize: $servingSize,
                                        unit: unit,
                                        showsExtendedFields: true)
                    }
                    .appCard()
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle(name.isEmpty ? "Nutrition" : name)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissControls()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// One ingredient's name, amount and label values.
struct IngredientSheet: View {
    @Binding var ingredient: IngredientDraft
    let isNew: Bool
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Ingredient", text: $ingredient.name)
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .textInputAutocapitalization(.words)
                            .focused($nameFocused)
                        HStack(spacing: 8) {
                            Text("Amount")
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 4)
                            QuantityStepper(quantity: $ingredient.quantity, unit: ingredient.unit)
                            UnitPicker(unit: $ingredient.unit)
                        }
                        NutritionSummaryView(nutrition: ingredient.total)
                    }
                    .appCard()

                    NutritionEditor(nutrition: $ingredient.nutritionPerServing,
                                    servingSize: $ingredient.servingSize,
                                    unit: ingredient.unit)
                        .appCard()

                    if ingredient.provenance != .manual {
                        Text("Values from \(ingredient.provenance.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !isNew {
                        Button(role: .destructive) {
                            dismiss()
                            onRemove()
                        } label: {
                            Text("Remove ingredient")
                                .font(.system(.body, design: .rounded).weight(.bold))
                                .foregroundStyle(AppTheme.destructiveText)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .overlay(Capsule().stroke(AppTheme.destructiveText.opacity(0.3),
                                                          lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle(isNew ? "New ingredient" : "Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissControls()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { if isNew { nameFocused = true } }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Shared

/// Dashed capsule for "Add another food" and "Add ingredient".
struct DashedAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(Capsule().strokeBorder(
                    AppTheme.stillToGo,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
