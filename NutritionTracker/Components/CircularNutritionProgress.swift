import SwiftUI

// MARK: - Range ring

/// The ring every nutrient display is drawn with: consumed against a target
/// that is a band, not a point (spec section 13).
///
/// - The empty track runs all the way round.
/// - The in-range zone is shaded from the minimum (marked with a tick) round
///   to the maximum at the top, so "on track" is visible at a glance.
/// - The consumed arc fills clockwise from the top in the state colour:
///   under keeps the nutrient's own colour (normal for most of the day),
///   within turns green, over turns orange.
/// - Going past the maximum draws a second lap over the first, with a soft
///   shadow on top so it reads as wrapping rather than just "full".
///
/// The stroke is kept inside the view's frame, so callers size it with a
/// plain `.frame`.
struct RangeRing: View {
    let progress: Double
    let bandStart: Double
    let tint: Color
    let bandTint: Color
    var lineWidth: CGFloat = 8
    var trackColor: Color = AppTheme.subtleFill

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is drawn; animates towards `progress` on appear and on change.
    @State private var shown: Double = 0

    private var band: Double { min(max(bandStart, 0), 1) }
    /// Capped at two laps: past that, the extra amount stops adding meaning.
    private var target: Double { min(max(progress.isFinite ? progress : 0, 0), 2) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)

            // In-range zone, minimum round to maximum.
            Circle()
                .trim(from: band, to: 1)
                .stroke(bandTint.opacity(0.22),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .opacity(band < 1 ? 1 : 0)

            // Crisp tick where the minimum is.
            Circle()
                .trim(from: max(band - 0.005, 0), to: min(band + 0.005, 1))
                .stroke(bandTint.opacity(0.75),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .opacity(band > 0 && band < 1 ? 1 : 0)

            // First lap. Always in the hierarchy (faded out at zero) so its
            // trim animates instead of popping in; this also avoids the round
            // cap drawing a stray dot when nothing has been eaten.
            Circle()
                .trim(from: 0, to: min(shown, 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(shown > 0.001 ? 1 : 0)

            // Second lap, past the maximum.
            Circle()
                .trim(from: 0, to: max(0, min(shown - 1, 0.999)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .black.opacity(0.28), radius: lineWidth * 0.4)
                .opacity(shown > 1.001 ? 1 : 0)
        }
        .padding(lineWidth / 2)
        .onAppear { animate() }
        .onChange(of: target) { _, _ in animate() }
    }

    private func animate() {
        if reduceMotion {
            shown = target
        } else {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.86)) { shown = target }
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
                    .frame(width: 66, height: 66)

                Text(AppFormatters.amount(consumed))
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(state == .over ? AppTheme.over : AppTheme.ink)
                    .contentTransition(.numericText())
                    .frame(width: 42)
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

/// Today's calorie summary: the running total beside a large ring.
struct CalorieHeroCard: View {
    let consumed: Double
    let range: NutrientRange

    private var state: RangeState { range.state(consumed: consumed) }
    private var progress: Double { range.progress(consumed: consumed) }
    private var tint: Color { AppTheme.color(for: state, nutrient: .calories) }

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
                          tint: tint,
                          bandTint: AppTheme.color(for: .calories),
                          lineWidth: 13,
                          trackColor: AppTheme.heroTrack)
                ringCentre
            }
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
        }
        .appSkyCard()
        .accessibilityElement(children: .combine)
    }

    /// What the centre says depends on the state, so it adds information
    /// rather than repeating the number beside it.
    @ViewBuilder
    private var ringCentre: some View {
        if range.max <= 0 {
            Text("\u{2013}")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(.secondary)
        } else {
            switch state {
            case .under:
                // How far towards the minimum - the point where the day counts
                // as on track.
                VStack(spacing: 0) {
                    Text("\(Int((consumed / max(range.min, 1) * 100).rounded()))%")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of min")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.skyCardText)
                }
            case .within:
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(tint)
            case .over:
                VStack(spacing: 0) {
                    Text("+\(AppFormatters.amount(consumed - range.max))")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("kcal over")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(tint)
                .frame(width: 76)
            }
        }
    }
}
