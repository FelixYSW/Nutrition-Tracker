import SwiftUI

/// Compact macro read-out used under rings, on cards and in the Calendar totals.
struct NutritionSummaryView: View {
    let nutrition: Nutrition
    var showsFibre: Bool = true
    /// Off where calories are already shown beside it, e.g. a food card's
    /// header, so the number never appears twice.
    var showsCalories: Bool = true

    private var items: [Nutrient] {
        Nutrient.allCases.filter { nutrient in
            switch nutrient {
            case .calories: showsCalories
            case .fibre: showsFibre
            default: true
            }
        }
    }

    var body: some View {
        // One row when it fits - all the macros side by side - and a grid
        // that reflows at large Dynamic Type sizes, rather than clipping.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(items) { nutrient in
                    cell(for: nutrient)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(items) { nutrient in
                    cell(for: nutrient)
                }
            }
        }
    }

    private func cell(for nutrient: Nutrient) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nutrient.displayName.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Text("\(AppFormatters.amount(nutrition[nutrient]))\(nutrient == .calories ? "" : "g")")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What was eaten against each target range, one row per nutrient: the
/// amount, the min-max band, and whether it's below, within or over.
///
/// For a finished day (or a period's average), falling short of a minimum
/// is shown as a miss - the minimum is a real target, not optional. While
/// the day is still going it reads as "to go".
struct NutritionRangeSummaryView: View {
    let nutrition: Nutrition
    let ranges: NutritionTargetRanges?
    var isComplete: Bool = true

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(Nutrient.allCases) { nutrient in
                row(for: nutrient)
            }
        }
    }

    private func row(for nutrient: Nutrient) -> some View {
        let unit = nutrient == .calories ? "kcal" : "g"
        let value = nutrition[nutrient]
        let range = ranges?[nutrient]
        return GridRow(alignment: .firstTextBaseline) {
            Text(nutrient.displayName)
                .font(.subheadline)
            Text("\(AppFormatters.amount(value)) \(unit)")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            Text(range.map { $0.max > 0 ? "of \(AppFormatters.range($0))" : "" } ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(range.map { status(value: value, range: $0, unit: unit) } ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(range.map { statusColor(value: value, range: $0) } ?? .secondary)
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func status(value: Double, range: NutrientRange, unit: String) -> String {
        guard range.max > 0 else { return "" }
        switch range.state(consumed: value) {
        case .under:
            let gap = AppFormatters.amount(range.min.rounded() - value.rounded())
            return isComplete ? "\(gap) \(unit) short" : "\(gap) \(unit) to go"
        case .within: return "In range"
        case .over: return "\(AppFormatters.amount(value.rounded() - range.max.rounded())) \(unit) over"
        }
    }

    private func statusColor(value: Double, range: NutrientRange) -> Color {
        switch range.state(consumed: value) {
        case .under: .secondary
        case .within: AppTheme.within
        case .over: AppTheme.over
        }
    }
}

/// The selected day on the Calendar: the date, calories against the range with
/// the flame from the app icon, and one tinted tile per macro.
struct DaySummaryCard: View {
    let date: Date
    let nutrition: Nutrition
    let ranges: NutritionTargetRanges?

    private let macros: [Nutrient] = [.protein, .carbs, .fat, .fibre]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            calories
            HStack(spacing: 8) {
                ForEach(macros) { nutrient in
                    tile(for: nutrient)
                }
            }
        }
        .appCard()
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(AppFormatters.weekdayName.string(from: date))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(AppFormatters.dayAndMonth.string(from: date))
                    .font(.system(.title3, design: .rounded).weight(.heavy))
            }
            Spacer()
            if LocalDay.isToday(date) {
                Text("Today")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(AppTheme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(AppTheme.accentFill, in: Capsule())
            }
        }
    }

    private var calories: some View {
        let range = ranges?[.calories]
        return HStack(spacing: 12) {
            Image(systemName: "flame.fill")
                .font(.system(size: 22))
                .foregroundStyle(AppTheme.flame)
                .frame(width: 48, height: 48)
                .background(AppTheme.flame.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(AppFormatters.amount(nutrition.calories))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("kcal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let range, range.max > 0 {
                        Text("range \(AppFormatters.range(range))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let range, range.max > 0 {
                    RangeBar(consumed: nutrition.calories, range: range, nutrient: .calories)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tile(for nutrient: Nutrient) -> some View {
        let tint = AppTheme.color(for: nutrient)
        return VStack(spacing: 3) {
            Image(systemName: nutrient.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text("\(AppFormatters.amount(nutrition[nutrient])) g")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(nutrient.displayName)
                .font(.caption2.weight(.semibold))
            if let range = ranges?[nutrient], range.max > 0 {
                Text(AppFormatters.range(range))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
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

            // Calories are in the header; the row has every macro plus fibre.
            NutritionSummaryView(nutrition: entry.total, showsFibre: true, showsCalories: false)

            if entry.isComposite {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        DisclosureChevron(isExpanded: isExpanded)
                            .font(.caption2)
                        Text(isExpanded ? "Hide ingredients"
                                        : "\(entry.ingredients.count) ingredients")
                    }
                    .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)

                if isExpanded {
                    // A grid, so every portion and every kcal figure lines up
                    // in its own right-aligned column whatever the name length.
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(entry.orderedIngredients) { ingredient in
                            GridRow(alignment: .firstTextBaseline) {
                                Text(ingredient.name)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(AppFormatters.quantity(ingredient.quantity, unit: ingredient.unit))\(ingredient.unit.shortLabel)")
                                    .gridColumnAlignment(.trailing)
                                Text("\(AppFormatters.amount(ingredient.total.calories)) kcal")
                                    .gridColumnAlignment(.trailing)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
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
