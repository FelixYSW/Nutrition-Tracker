import SwiftUI

/// One food being typed in or changed, as a native iOS form (spec sections
/// 10, 12). Used by New food and Edit food.
///
/// Everything is on one screen: the name, how much was eaten, what that
/// adds up to, and the label values typed straight into their rows. A dish
/// made of several parts lists its ingredients instead, each opening on its
/// own screen pushed inside the same sheet - no sheets stacked on sheets.
struct FoodEditor: View {
    @Binding var draft: FoodEntryDraft
    /// Edit food sets its own time; in Add food the meal has one time.
    var showsTime = false
    /// Shown as a red button at the bottom when set.
    var removeTitle: String?
    var onRemove: (() -> Void)?

    @State private var openIngredient: IngredientRoute?
    @State private var showsMoreNutrients = false
    @State private var isConfirmingRemove = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Group {
                nameSection
                amountSection
                totalSection
                if draft.isComposite {
                    ingredientsSection
                } else {
                    labelSection
                }
                if showsTime {
                    Section {
                        DatePicker("Eaten at", selection: $draft.consumedAt,
                                   in: ...Date.now.addingTimeInterval(60 * 60),
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }
            .listRowBackground(AppTheme.cardBackground)
            // Outside the group above, so its red row background isn't
            // replaced by the card colour.
            if let removeTitle, onRemove != nil {
                Section {
                    Button(role: .destructive) {
                        isConfirmingRemove = true
                    } label: {
                        Label(removeTitle, systemImage: "trash")
                    }
                    .buttonStyle(.appDestructive)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationDestination(item: $openIngredient) { route in
            if let binding = ingredientBinding(id: route.id) {
                IngredientEditor(ingredient: binding)
            }
        }
        .onChange(of: openIngredient) { _, route in
            // Back from an ingredient left blank: it isn't kept.
            if route == nil { dropEmptyIngredients() }
        }
        .confirmationDialog("\(removeTitle ?? "Remove") \(draft.name.isEmpty ? "this food" : draft.name)?",
                            isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button(removeTitle ?? "Remove", role: .destructive) { onRemove?() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            if draft.name.isEmpty { isNameFocused = true }
            if draft.nutritionPerServing.sugar > 0 || draft.nutritionPerServing.sodium > 0 {
                showsMoreNutrients = true
            }
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section {
            TextField("Food name, e.g. Nasi lemak", text: $draft.name, axis: .vertical)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .textInputAutocapitalization(.words)
                .lineLimit(1...3)
                .focused($isNameFocused)
                .submitLabel(.done)
        } footer: {
            if draft.source != .manual || draft.hasLowConfidenceItems {
                HStack(spacing: 6) {
                    Label("From \(draft.source.displayName.lowercased())",
                          systemImage: draft.source.symbolName)
                    if draft.hasLowConfidenceItems {
                        Text("\u{00B7} check the amounts")
                    }
                }
            }
        }
    }

    private var amountSection: some View {
        Section {
            HStack(spacing: 8) {
                Text(draft.isComposite ? "Servings" : "Amount eaten")
                Spacer(minLength: 4)
                QuantityStepper(quantity: $draft.quantity, unit: draft.unit) {
                    draft.quantity = draft.unit.step
                }
                if !draft.isComposite {
                    UnitPicker(unit: $draft.unit)
                }
            }
        }
    }

    /// What the portion eaten comes to, updating as anything changes.
    private var totalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(AppFormatters.amount(draft.total.calories))
                        .scaledHeavyNumber(30, relativeTo: .title)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("kcal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                NutritionSummaryView(nutrition: draft.total, showsCalories: false)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        } header: {
            Text("This portion")
        } footer: {
            if !draft.isSaveable {
                Text("Add a name and its nutrition to save it.")
            }
        }
    }

    /// The figures from the packet, per the serving size they're given for.
    private var labelSection: some View {
        Section {
            NumberRow(title: "Per", value: $draft.servingSize, unit: draft.unit.shortLabel,
                      help: "The amount the label's figures are for")
            NumberRow(title: "Calories", value: $draft.nutritionPerServing.calories, unit: "kcal")
            NumberRow(title: "Protein", value: $draft.nutritionPerServing.protein, unit: "g")
            NumberRow(title: "Carbs", value: $draft.nutritionPerServing.carbs, unit: "g")
            NumberRow(title: "Fat", value: $draft.nutritionPerServing.fat, unit: "g")
            NumberRow(title: "Fibre", value: $draft.nutritionPerServing.fibre, unit: "g")
            if showsMoreNutrients {
                NumberRow(title: "Sugar", value: $draft.nutritionPerServing.sugar, unit: "g")
                NumberRow(title: "Sodium", value: $draft.nutritionPerServing.sodium, unit: "mg")
            } else {
                Button("Add sugar and sodium") {
                    withAnimation(.snappy) { showsMoreNutrients = true }
                }
            }
            Button {
                addIngredient()
            } label: {
                Label("Made of several parts? Add ingredients", systemImage: "list.bullet.indent")
            }
        } header: {
            Text("Nutrition label")
        } footer: {
            Text("Copy the figures from the packet. What you ate is worked out from these "
                 + "and the amount above.")
        }
    }

    private var ingredientsSection: some View {
        Section {
            ForEach(draft.ingredients) { ingredient in
                Button {
                    openIngredient = IngredientRoute(id: ingredient.id)
                } label: {
                    IngredientRow(ingredient: ingredient)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                draft.ingredients.remove(atOffsets: offsets)
                Haptics.selection()
            }
            Button {
                addIngredient()
            } label: {
                Label("Add ingredient", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Ingredients")
        } footer: {
            Text("Swipe left on an ingredient to remove it.")
        }
    }

    // MARK: Actions

    private func addIngredient() {
        // Turning a single food into a dish carries what was typed into the
        // first ingredient, so nothing is lost.
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
        } else if draft.ingredients.isEmpty {
            draft.quantity = 1
            draft.servingSize = 1
            draft.unit = .serving
        }
        let added = IngredientDraft(name: "", quantity: 100, servingSize: 100, unit: .gram)
        draft.ingredients.append(added)
        openIngredient = IngredientRoute(id: added.id)
        Haptics.selection()
    }

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

/// Which ingredient is open.
struct IngredientRoute: Identifiable, Hashable {
    let id: UUID
}

// MARK: - Rows

/// One ingredient in the dish: name, amount and calories, opening its editor.
private struct IngredientRow: View {
    let ingredient: IngredientDraft

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ingredient.name.isEmpty ? "Unnamed" : ingredient.name)
                        .foregroundStyle(ingredient.name.isEmpty ? Color.secondary : AppTheme.ink)
                        .multilineTextAlignment(.leading)
                    if ingredient.isLowConfidence {
                        ConfidenceBadge(confidence: ingredient.confidence)
                    }
                }
                Text("\(AppFormatters.quantity(ingredient.quantity, unit: ingredient.unit)) "
                     + ingredient.unit.shortLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(AppFormatters.amount(ingredient.total.calories)) kcal")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: AppTheme.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit this ingredient")
    }
}

/// A form row for one number: its name on the left, the value typed on the
/// right with the unit after it - like Settings rows.
struct NumberRow: View {
    let title: String
    @Binding var value: Double
    let unit: String
    var help: String?

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($isFocused)
                .frame(maxWidth: 110)
                .onChange(of: text) { _, newValue in
                    value = NumericEntryField.parse(newValue)
                }
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear(perform: sync)
        .onChange(of: value) { _, newValue in
            if !isFocused, NumericEntryField.parse(text) != newValue { sync() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(unit)")
        .accessibilityHint(help ?? "")
    }

    private func sync() {
        // Label figures keep their decimals: 2.7 g of protein, 0.4 g of fibre.
        text = value == 0 ? "" : value.formatted(.number.precision(.fractionLength(0...2))
                                                    .grouping(.never))
    }
}

// MARK: - Ingredient

/// One ingredient's name, amount and label figures, pushed inside the food's
/// sheet. Back returns to the dish.
struct IngredientEditor: View {
    @Binding var ingredient: IngredientDraft
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("Ingredient, e.g. Fried egg", text: $ingredient.name)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .textInputAutocapitalization(.words)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                } footer: {
                    if ingredient.provenance != .manual {
                        Text("Figures from \(ingredient.provenance.displayName)")
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Text("Amount")
                        Spacer(minLength: 4)
                        QuantityStepper(quantity: $ingredient.quantity, unit: ingredient.unit) {
                            ingredient.quantity = ingredient.unit.step
                        }
                        UnitPicker(unit: $ingredient.unit)
                    }
                    HStack {
                        Text("Comes to")
                        Spacer()
                        Text("\(AppFormatters.amount(ingredient.total.calories)) kcal")
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                }

                Section {
                    NumberRow(title: "Per", value: $ingredient.servingSize,
                              unit: ingredient.unit.shortLabel,
                              help: "The amount the figures below are for")
                    NumberRow(title: "Calories", value: $ingredient.nutritionPerServing.calories,
                              unit: "kcal")
                    NumberRow(title: "Protein", value: $ingredient.nutritionPerServing.protein, unit: "g")
                    NumberRow(title: "Carbs", value: $ingredient.nutritionPerServing.carbs, unit: "g")
                    NumberRow(title: "Fat", value: $ingredient.nutritionPerServing.fat, unit: "g")
                    NumberRow(title: "Fibre", value: $ingredient.nutritionPerServing.fibre, unit: "g")
                } header: {
                    Text("Nutrition")
                }
            }
            .listRowBackground(AppTheme.cardBackground)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(ingredient.name.isEmpty ? "New ingredient" : ingredient.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if ingredient.name.isEmpty { isNameFocused = true } }
    }
}
