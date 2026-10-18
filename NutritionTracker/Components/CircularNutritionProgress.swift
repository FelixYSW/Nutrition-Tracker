import SwiftUI

// MARK: - Range ring

/// The ring every nutrient display is drawn with: consumed against a target
/// that is a band, not a point (spec section 13).
///
/// - The empty track runs all the way round.
/// - The in-range zone is shaded from the minimum (marked with a tick) round
///   to the maximum at the top, so "on track" is visible at a glance.
/// - The consumed arc fills clockwise from the top in the nutrient's own
///   colour. The ring looks the same whether the user is under, in range or
///   over - the caption underneath is what says which; going over simply
///   shows a full ring.
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
    /// Capped at one full turn: over the maximum just shows a full ring.
    private var target: Double { min(max(progress.isFinite ? progress : 0, 0), 1) }

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

/// Colour for the status caption under a ring. The ring itself never changes
/// with the state; only this line does: "… to go" stays plain, "In range" is
/// green and "… over" is the warm orange.
private func captionColor(for state: RangeState, normal: Color) -> Color {
    switch state {
    case .under: normal
    case .within: AppTheme.within
    case .over: AppTheme.over
    }
}

/// Short plain-language status for a nutrient against its range.
private func rangeCaption(nutrient: Nutrient, consumed: Double, range: NutrientRange) -> String {
    guard range.max > 0 else { return "No target" }
    let unit = nutrient == .calories ? " kcal" : " g"
    switch range.state(consumed: consumed) {
    // Worked out from the whole numbers on screen, like the state itself, so
    // the gap is always at least 1 and matches the figures shown.
    case .under:
        return "\(AppFormatters.amount(range.min.rounded() - consumed.rounded()))\(unit) to go"
    case .within:
        return "In range"
    case .over:
        return "\(AppFormatters.amount(consumed.rounded() - range.max.rounded()))\(unit) over"
    }
}

/// One of the four small macro rings on Today: amount in the centre, with the
/// name, band and what is left underneath.
struct CompactMacroRing: View {
    let nutrient: Nutrient
    let consumed: Double
    let range: NutrientRange


    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RangeRing(progress: range.progress(consumed: consumed),
                          bandStart: range.bandFractions().start,
                          tint: AppTheme.color(for: nutrient),
                          bandTint: AppTheme.color(for: nutrient),
                          lineWidth: 7)
                    .frame(width: 66, height: 66)

                Image(systemName: nutrient.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.color(for: nutrient))
            }

            Text(nutrient.displayName)
                .font(.footnote.weight(.bold))
            Text("\(AppFormatters.amount(consumed)) \(nutrient.unitLabel)")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .contentTransition(.numericText())
            VStack(spacing: 1) {
                Text("\(AppFormatters.range(range)) \(nutrient.unitLabel)")
                Text(rangeCaption(nutrient: nutrient, consumed: consumed, range: range))
                    .foregroundStyle(captionColor(for: range.state(consumed: consumed),
                                                  normal: .secondary))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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

    private var progress: Double { range.progress(consumed: consumed) }
    /// The ring is ink, like the app icon; the flame inside carries the colour.
    private var tint: Color { AppTheme.accentFill }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RangeRing(progress: progress,
                          bandStart: range.bandFractions().start,
                          tint: tint,
                          bandTint: AppTheme.within,
                          lineWidth: 13,
                          trackColor: AppTheme.subtleFill)
                ringCentre
            }
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Calories")
                        .textCase(.uppercase)
                        .tracking(0.6)
                } icon: {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(AppTheme.flame)
                }
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.textColor(for: .calories))

                Text(AppFormatters.amount(consumed))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())

                if range.max > 0 {
                    let state = range.state(consumed: consumed)
                    Text("of \(AppFormatters.range(range)) kcal")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.skyCardText)
                    // Status pill tinted by state: neutral while under, green
                    // in range, orange over.
                    Text(rangeCaption(nutrient: .calories, consumed: consumed, range: range))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.stateTextColor(for: state))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(AppTheme.stateFill(for: state), in: Capsule())
                        .padding(.top, 4)
                } else {
                    Text("No targets yet. Set them in Settings.")
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .appCard()
        .accessibilityElement(children: .combine)
    }

    /// The same in every state. Whether that's under, in range or over is
    /// said by the pill beside the ring, not by the ring itself.
    @ViewBuilder
    private var ringCentre: some View {
        if range.max <= 0 {
            Text("\u{2013}")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(.secondary)
        } else {
            // Just the flame, like the app icon; the numbers sit beside it.
            Image(systemName: "flame.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.flame)
        }
    }
}
