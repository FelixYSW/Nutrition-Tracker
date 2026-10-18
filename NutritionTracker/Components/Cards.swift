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
            // Every tile as tall as the tallest, so they line up as one row.
            HStack(alignment: .top, spacing: 8) {
                ForEach(items) { nutrient in
                    cell(for: nutrient)
                        .frame(maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(items) { nutrient in
                    cell(for: nutrient)
                }
            }
        }
    }

    /// A tinted tile per nutrient: its symbol, the amount and its name.
    private func cell(for nutrient: Nutrient) -> some View {
        let tint = AppTheme.color(for: nutrient)
        return VStack(spacing: 3) {
            // A fixed slot: the symbols differ in height (the flame and fork
            // are taller than the drop), which put each number at a
            // different height.
            Image(systemName: nutrient.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 18)
                .accessibilityHidden(true)
            Text("\(AppFormatters.amount(nutrition[nutrient]))\(nutrient == .calories ? "" : "g")")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(nutrient == .calories ? "kcal" : nutrient.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 9)
        .padding(.horizontal, 2)
        .background(tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The Calendar's summary card: calories against the range with the flame
/// from the app icon, and one tinted tile per macro. Shows a single day, or
/// a week's or month's daily average in exactly the same layout.
struct DaySummaryCard: View {
    /// Small line above the title: the weekday, or "Daily average".
    let overline: String
    /// The date, or the period ("6 Oct – 12 Oct", "October 2026").
    let title: String
    /// Capsule on the right: "Today", "This week", or none.
    let badge: String?
    let nutrition: Nutrition
    let ranges: NutritionTargetRanges?
    /// Extra line under the tiles, e.g. "5 of 7 days logged".
    var footnote: String?

    private let macros: [Nutrient] = [.protein, .carbs, .fat, .fibre]

    /// One day's totals.
    init(date: Date, nutrition: Nutrition, ranges: NutritionTargetRanges?) {
        self.overline = AppFormatters.weekdayName.string(from: date)
        self.title = AppFormatters.dayAndMonth.string(from: date)
        self.badge = LocalDay.isToday(date) ? "Today" : nil
        self.nutrition = nutrition
        self.ranges = ranges
        self.footnote = nil
    }

    /// Any other figures, such as a week's daily average.
    init(overline: String, title: String, badge: String?, nutrition: Nutrition,
         ranges: NutritionTargetRanges?, footnote: String? = nil) {
        self.overline = overline
        self.title = title
        self.badge = badge
        self.nutrition = nutrition
        self.ranges = ranges
        self.footnote = footnote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            calories
            // Equal-height tiles, so the four line up as one row.
            HStack(alignment: .top, spacing: 8) {
                ForEach(macros) { nutrient in
                    tile(for: nutrient)
                        .frame(maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appCard()
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(overline)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            Spacer()
            if let badge {
                Text(badge)
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
                    RangeBar(consumed: nutrition.calories, range: range, nutrient: .calories,
                             fill: AppTheme.accentFill, band: AppTheme.within)
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
                .frame(height: 20)   // the same slot for every symbol
                .accessibilityHidden(true)
            Text("\(AppFormatters.amount(nutrition[nutrient])) g")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(nutrient.displayName)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let range = ranges?[nutrient], range.max > 0 {
                Text(AppFormatters.range(range))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: entry.source.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.skyCard,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(AppFormatters.time.string(from: entry.consumedAt))
                        Text("\u{00B7}")
                        Text("\(AppFormatters.quantity(entry.quantity, unit: entry.unit)) \(entry.unit.shortLabel)")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(AppFormatters.amount(entry.total.calories))
                        .font(.system(.body, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                    Text("kcal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            // Collapsed, a card is just name, time and calories. Opening it
            // shows the macros and, for a composite food, its ingredients.
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                // Chevrons sit before their text, everywhere in the app.
                HStack(spacing: 6) {
                    DisclosureChevron(isExpanded: isExpanded)
                        .font(.caption.weight(.bold))
                    Text(detailsLabel)
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: AppTheme.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isExpanded {
                NutritionSummaryView(nutrition: entry.total, showsFibre: true, showsCalories: false)

                if entry.isComposite {
                    // A grid, so every portion and every kcal figure lines up
                    // in its own right-aligned column whatever the name length.
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(entry.orderedIngredients) { ingredient in
                            GridRow(alignment: .firstTextBaseline) {
                                Text(ingredient.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(AppFormatters.quantity(ingredient.quantity, unit: ingredient.unit))\(ingredient.unit.shortLabel)")
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text("\(AppFormatters.amount(ingredient.total.calories)) kcal")
                                    .fontWeight(.semibold)
                                    .gridColumnAlignment(.trailing)
                            }
                            .font(.footnote)
                            .monospacedDigit()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 10)
                    .overlay(alignment: .top) {
                        Rectangle().fill(AppTheme.cardBorder).frame(height: 1)
                    }
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

extension FoodEntryCard {
    fileprivate var detailsLabel: String {
        if isExpanded { return entry.isComposite ? "Hide ingredients" : "Hide nutrition" }
        return entry.isComposite ? "\(entry.ingredients.count) ingredients" : "Nutrition"
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
            .background(isLow ? AppTheme.over.opacity(0.16) : AppTheme.within.opacity(0.16),
                        in: Capsule())
            .foregroundStyle(AppTheme.stateTextColor(for: isLow ? .over : .within))
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
