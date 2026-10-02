import SwiftUI

/// Ring showing consumed-vs-target where the target is a band, not a point
/// (spec section 13).
///
/// Three states:
///  - under  - below the minimum. Normal for most of the day; shown calmly.
///  - within - inside the band. Reads as "on track".
///  - over   - above the maximum. Flagged distinctly, factually, without
///             medical framing.
///
/// The ring track itself shades the min-max zone so the user can see where
/// "in range" sits at a glance rather than having to read the numbers.
struct CircularNutritionProgress: View {
    let nutrient: Nutrient
    let consumed: Double
    let range: NutrientRange

    var lineWidth: CGFloat = 11
    var showsLabel: Bool = true

    private var state: RangeState { range.state(consumed: consumed) }
    private var progress: Double { range.progress(consumed: consumed) }
    private var bandStart: Double { range.bandFractions().start }
    private var tint: Color { AppTheme.color(for: state, nutrient: nutrient) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Empty track.
                Circle()
                    .stroke(AppTheme.subtleFill, lineWidth: lineWidth)

                // Shaded in-range zone: from the minimum round to the maximum.
                Circle()
                    .trim(from: bandStart, to: 1)
                    .stroke(AppTheme.color(for: nutrient).opacity(0.22),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))

                // Consumed arc, capped at one full turn so going far over does
                // not wrap confusingly round the ring.
                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.28), value: progress)

                // A second, inset arc marks the overflow past the maximum.
                if progress > 1 {
                    Circle()
                        .trim(from: 0, to: min(progress - 1, 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth * 0.4,
                                                         lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(lineWidth * 1.1)
                }

                centreContent
            }
            .aspectRatio(1, contentMode: .fit)

            if showsLabel {
                Text(nutrient.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nutrient.displayName)
        .accessibilityValue(accessibilityDescription)
    }

    private var centreContent: some View {
        VStack(spacing: 1) {
            Text(AppFormatters.amount(consumed))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(AppFormatters.range(range))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if state == .over {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
        }
        // Keeps the text inside the ring rather than letting large Dynamic Type
        // sizes push it over the stroke.
        .padding(lineWidth * 1.6)
    }

    private var accessibilityDescription: String {
        let unit = nutrient.unitLabel
        let base = "\(AppFormatters.amount(consumed)) \(unit) of a "
            + "\(AppFormatters.amount(range.min)) to \(AppFormatters.amount(range.max)) \(unit) range."
        switch state {
        case .under:
            let gap = AppFormatters.amount(max(0, range.min - consumed))
            return base + " \(gap) \(unit) to go to reach your minimum."
        case .within:
            return base + " On track."
        case .over:
            let excess = AppFormatters.amount(consumed - range.max)
            return base + " \(excess) \(unit) over your range."
        }
    }
}

/// One-line prompt that accompanies a ring.
///
/// Copy stays factual and non-judgemental: an "over" day is a nutritional
/// heads-up, not a warning about the user's health (spec sections 1 and 13).
struct RangeStatusMessage: View {
    let nutrient: Nutrient
    let consumed: Double
    let range: NutrientRange

    private var state: RangeState { range.state(consumed: consumed) }

    var body: some View {
        if let message {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(AppTheme.color(for: state, nutrient: nutrient))
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var symbol: String {
        switch state {
        case .under: "arrow.up.circle"
        case .within: "checkmark.circle.fill"
        case .over: "exclamationmark.triangle.fill"
        }
    }

    private var message: String? {
        let unit = nutrient.unitLabel
        switch state {
        case .under:
            let gap = range.min - consumed
            guard gap > 0 else { return nil }
            return "\(AppFormatters.amount(gap))\(unit) \(nutrient.displayName.lowercased()) to go to reach your minimum."
        case .within:
            return "\(nutrient.displayName) is in range."
        case .over:
            let excess = consumed - range.max
            return "You're \(AppFormatters.amount(excess))\(unit) over your \(nutrient.displayName.lowercased()) range today."
        }
    }
}

#Preview("Range states") {
    let range = NutrientRange(min: 120, max: 160)
    return HStack(spacing: 16) {
        CircularNutritionProgress(nutrient: .protein, consumed: 60, range: range)
        CircularNutritionProgress(nutrient: .protein, consumed: 140, range: range)
        CircularNutritionProgress(nutrient: .protein, consumed: 190, range: range)
    }
    .padding()
}

// MARK: - Range ring primitive and the Today summary views

/// Ring track with the shaded in-range zone and a consumed arc. Shared by the
/// calorie hero and the compact macro rings so both read the same way.
struct RangeRing: View {
    let progress: Double
    let bandStart: Double
    let tint: Color
    let bandTint: Color
    var lineWidth: CGFloat = 8
    var trackColor: Color = AppTheme.subtleFill

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)

            Circle()
                .trim(from: min(max(bandStart, 0), 1), to: 1)
                .stroke(bandTint.opacity(0.28),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.28), value: progress)
        }
    }
}

/// Short plain-language status for a nutrient against its range.
private func rangeCaption(nutrient: Nutrient, consumed: Double, range: NutrientRange) -> String {
    guard range.max > 0 else { return "No target" }
    let unit = nutrient == .calories ? " kcal" : " g"
    switch range.state(consumed: consumed) {
    case .under:
        return "\(AppFormatters.amount(max(0, range.min - consumed)))\(unit) to go"
    case .within:
        return "In range"
    case .over:
        return "\(AppFormatters.amount(consumed - range.max))\(unit) over"
    }
}

/// One of the four small macro rings on Today: amount in the centre, with the
/// name, band and what is left underneath.
struct CompactMacroRing: View {
    let nutrient: Nutrient
    let consumed: Double
    let range: NutrientRange

    private var state: RangeState { range.state(consumed: consumed) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RangeRing(progress: range.progress(consumed: consumed),
                          bandStart: range.bandFractions().start,
                          tint: AppTheme.color(for: state, nutrient: nutrient),
                          bandTint: AppTheme.color(for: nutrient),
                          lineWidth: 7)
                    .frame(width: 64, height: 64)

                Text(AppFormatters.amount(consumed))
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .frame(width: 40)
            }

            Text(nutrient.displayName)
                .font(.footnote.weight(.bold))
            VStack(spacing: 1) {
                Text("\(AppFormatters.range(range)) \(nutrient.unitLabel)")
                Text(rangeCaption(nutrient: nutrient, consumed: consumed, range: range))
            }
            .font(.caption2)
            .foregroundStyle(state == .over ? AppTheme.over : Color.secondary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nutrient.displayName)
        .accessibilityValue("\(AppFormatters.amount(consumed)) \(nutrient.unitLabel) of a "
                            + "\(AppFormatters.amount(range.min)) to \(AppFormatters.amount(range.max)) "
                            + "\(nutrient.unitLabel) range. "
                            + rangeCaption(nutrient: nutrient, consumed: consumed, range: range))
    }
}

/// Today's calorie summary: a pale blue card with the running total and a
/// large ring.
struct CalorieHeroCard: View {
    let consumed: Double
    let range: NutrientRange

    private var state: RangeState { range.state(consumed: consumed) }
    private var progress: Double { range.progress(consumed: consumed) }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calories so far")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.skyCardText)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(AppFormatters.amount(consumed))
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Text("kcal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.skyCardText)
                }

                if range.max > 0 {
                    Text("Range \(AppFormatters.range(range)).")
                        .font(.footnote)
                    Text(rangeCaption(nutrient: .calories, consumed: consumed, range: range))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(state == .over ? AppTheme.over : AppTheme.skyCardText)
                } else {
                    Text("No targets yet. Set them in Settings.")
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                RangeRing(progress: progress,
                          bandStart: range.bandFractions().start,
                          tint: AppTheme.color(for: .calories),
                          bandTint: AppTheme.accentFill,
                          lineWidth: 12,
                          trackColor: Color.white.opacity(0.55))
                Text("\(Int((min(progress, 9.99) * 100).rounded()))%")
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .monospacedDigit()
            }
            .frame(width: 108, height: 108)
            .accessibilityHidden(true)
        }
        .appSkyCard()
        .accessibilityElement(children: .combine)
    }
}
