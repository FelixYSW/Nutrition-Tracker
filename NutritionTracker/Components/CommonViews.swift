import SwiftUI

/// Empty state that always says what happened and what to do next
/// (spec section 33).
struct EmptyStateView: View {
    let title: String
    var message: String?
    var systemImage: String = "fork.knife"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.appPrimary)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }
}

/// Error state with a retry affordance. Used for network and model failures
/// (spec sections 33, 34).
struct ErrorStateView: View {
    let title: String
    let message: String
    var retryTitle: String = "Try Again"
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(.appSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}

/// Staged progress during photo analysis (spec section 28).
struct LoadingAnalysisView: View {
    let stage: AnalysisStage

    var body: some View {
        VStack(spacing: 18) {
            ProgressView(value: stage.fractionComplete)
                .progressViewStyle(.linear)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(AnalysisStage.orderedCases, id: \.self) { candidate in
                    HStack(spacing: 10) {
                        icon(for: candidate)
                            .frame(width: 20)
                        Text(candidate.displayName)
                            .font(.subheadline)
                            .foregroundStyle(candidate.order <= stage.order ? .primary : .secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            EstimateDisclaimer()
        }
        .appCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analysing photo. \(stage.displayName).")
    }

    @ViewBuilder
    private func icon(for candidate: AnalysisStage) -> some View {
        if candidate.order < stage.order {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accentFill)
                .accessibilityHidden(true)
        } else if candidate.order == stage.order {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

/// Numeric text field that tolerates an empty value and refuses to produce
/// NaN or a negative number (spec section 34).
///
/// An empty field reads as zero rather than blocking the user, and the hint
/// makes the unit explicit.
struct NumericEntryField: View {
    let title: String
    @Binding var value: Double
    var unitLabel: String?
    var allowsDecimal: Bool = true

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("0", text: $text)
                    .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
                    .multilineTextAlignment(.leading)
                    .monospacedDigit()
                    .focused($isFocused)
                    .onChange(of: text) { _, newValue in
                        value = Self.parse(newValue)
                    }
                if let unitLabel {
                    Text(unitLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.subtleFill,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .onAppear { syncText() }
        .onChange(of: value) { _, newValue in
            // Only overwrite the field when the change came from elsewhere,
            // otherwise typing "1." would be rewritten mid-entry.
            if !isFocused, Self.parse(text) != newValue { syncText() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func syncText() {
        text = value == 0 ? "" : AppFormatters.amount(value)
    }

    static func parse(_ string: String) -> Double {
        let cleaned = string
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        guard let parsed = Double(cleaned), parsed.isFinite, parsed >= 0 else { return 0 }
        return parsed
    }
}

/// Editor for one nutrition payload. Labels state clearly that figures are
/// *per serving size*, which is the usual source of confusion.
struct NutritionEditor: View {
    @Binding var nutrition: Nutrition
    @Binding var servingSize: Double
    let unit: ServingUnit
    var showsExtendedFields: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per \(AppFormatters.quantity(servingSize, unit: unit)) \(unit.shortLabel)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                NumericEntryField(title: "Serving size", value: $servingSize,
                                  unitLabel: unit.shortLabel)
                NumericEntryField(title: "Calories", value: $nutrition.calories,
                                  unitLabel: "kcal")
                NumericEntryField(title: "Protein", value: $nutrition.protein, unitLabel: "g")
                NumericEntryField(title: "Carbs", value: $nutrition.carbs, unitLabel: "g")
                NumericEntryField(title: "Fat", value: $nutrition.fat, unitLabel: "g")
                NumericEntryField(title: "Fibre", value: $nutrition.fibre, unitLabel: "g")
                if showsExtendedFields {
                    NumericEntryField(title: "Sugar", value: $nutrition.sugar, unitLabel: "g")
                    NumericEntryField(title: "Sodium", value: $nutrition.sodium, unitLabel: "mg")
                }
            }
        }
    }
}

/// A labelled native slider with its current value on the right. On iOS 26 the
/// thumb picks up the system glass look automatically.
struct SliderEntryRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unitLabel: String = ""
    var fractionDigits: Int = 0

    private var valueText: String {
        let number = value.formatted(.number.precision(.fractionLength(fractionDigits)))
        return unitLabel.isEmpty ? number : "\(number) \(unitLabel)"
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)

            Slider(value: Binding(
                get: { min(max(value, range.lowerBound), range.upperBound) },
                set: { value = $0 }),
                   in: range,
                   step: step)
                .tint(AppTheme.accentFill)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}
