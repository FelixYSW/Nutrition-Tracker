import SwiftUI

/// Compact macro read-out used under rings, on cards and in the Calendar totals.
struct NutritionSummaryView: View {
    let nutrition: Nutrition
    var showsFibre: Bool = true

    private var items: [Nutrient] {
        showsFibre ? Nutrient.allCases : Nutrient.allCases.filter(\.isPrimary)
    }

    var body: some View {
        // A grid rather than an HStack so it reflows instead of clipping at
        // large Dynamic Type sizes.
        let columns = [GridItem(.adaptive(minimum: 72), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(items) { nutrient in
                VStack(alignment: .leading, spacing: 2) {
                    Text(nutrient.displayName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(AppFormatters.amount(nutrition[nutrient]))\(nutrient == .calories ? "" : "g")")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A saved food on the Dashboard or in the Calendar. Composite foods expand to
/// reveal their ingredients (spec section 13).
struct FoodEntryCard: View {
    let entry: FoodEntry
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.source.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accentFill.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(AppFormatters.time.string(from: entry.consumedAt))
                        Text("\u{00B7}")
                        Text("\(AppFormatters.quantity(entry.quantity, unit: entry.unit)) \(entry.unit.shortLabel)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("\(AppFormatters.amount(entry.total.calories)) kcal")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            NutritionSummaryView(nutrition: entry.total, showsFibre: false)

            if entry.isComposite {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide ingredients"
                                        : "\(entry.ingredients.count) ingredients")
                        DisclosureChevron(isExpanded: isExpanded)
                            .font(.caption2)
                    }
                    .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.orderedIngredients) { ingredient in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ingredient.name)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text("\(AppFormatters.quantity(ingredient.quantity, unit: ingredient.unit))\(ingredient.unit.shortLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text("\(AppFormatters.amount(ingredient.total.calories)) kcal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .appCard()
        // Standard iOS affordances: swipe to delete, long-press for a menu.
        .contextMenu {
            if let onEdit {
                Button("Edit", systemImage: "pencil", action: onEdit)
            }
            if let onDelete {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(AppFormatters.amount(entry.total.calories)) calories")
    }
}

/// One ingredient inside a composite food: name, amount and calories on two
/// short lines. Its label values are tucked away until the row is opened, so a
/// five-ingredient dish stays readable.
struct IngredientRow: View {
    @Binding var draft: IngredientDraft
    @Binding var isExpanded: Bool
    var onDelete: () -> Void

    @State private var showRemovePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Ingredient", text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .font(.subheadline.weight(.semibold))
                    // On the tinted ingredient row, a card-coloured box stands out.
                    .inputBox(fill: AppTheme.cardBackground)

                if draft.isLowConfidence {
                    ConfidenceBadge(confidence: draft.confidence)
                }

                // Red so it reads as tappable; the food's total line already
                // carries the calories, so the row doesn't repeat them.
                Button("Remove", role: .destructive, action: onDelete)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("Remove \(draft.name.isEmpty ? "ingredient" : draft.name)")
            }

            HStack(spacing: 8) {
                QuantityStepper(quantity: $draft.quantity, unit: draft.unit) {
                    showRemovePrompt = true
                }
                UnitPicker(unit: $draft.unit)

                Spacer(minLength: 0)

                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    DisclosureChevron(isExpanded: isExpanded)
                        .frame(width: AppTheme.minimumTapTarget,
                               height: AppTheme.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "Hide nutrition" : "Edit nutrition")
            }

            if isExpanded {
                NutritionEditor(nutrition: $draft.nutritionPerServing,
                                servingSize: $draft.servingSize,
                                unit: draft.unit)

                if draft.provenance != .manual {
                    Text("Values from \(draft.provenance.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(AppTheme.subtleFill.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .alert("Remove \(draft.name.isEmpty ? "this ingredient" : draft.name)?",
               isPresented: $showRemovePrompt) {
            Button("Remove", role: .destructive, action: onDelete)
            Button("Keep", role: .cancel) {
                // Restore to one step so no zero-quantity row is left behind.
                draft.quantity = draft.unit.step
            }
        } message: {
            Text("The amount reached zero.")
        }
    }
}

/// Per-detection confidence, shown so the user knows what to check
/// (spec section 25).
struct ConfidenceBadge: View {
    let confidence: Double?

    var body: some View {
        if let confidence {
            let percent = Int((confidence * 100).rounded())
            let isLow = confidence < NutritionConstants.lowConfidenceThreshold
            HStack(spacing: 3) {
                if isLow {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
                Text("\(percent)%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isLow ? Color.orange.opacity(0.18) : Color.green.opacity(0.16),
                        in: Capsule())
            .foregroundStyle(isLow ? Color.orange : Color.green)
            .accessibilityLabel(isLow ? "Low confidence, \(percent) percent"
                                      : "Confidence \(percent) percent")
        }
    }
}

/// The app's one show/hide chevron, so every expandable section follows the
/// same rule: pointing up while collapsed, down while open. Rotates between
/// the two so the change animates with the section.
struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .rotationEffect(.degrees(isExpanded ? 0 : 180))
            .accessibilityHidden(true)
    }
}
