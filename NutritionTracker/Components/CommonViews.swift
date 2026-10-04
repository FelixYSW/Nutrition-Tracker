import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
                .foregroundStyle(AppTheme.within)
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
    /// Hidden when the field sits inline after its own label.
    var showsTitle: Bool = true

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
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

/// Editor for the label values of a food: "per 100 g, it has ...".
///
/// The serving size sits inline in the heading rather than as one more field,
/// because it is what the numbers below refer to - the usual source of
/// confusion. The amount actually eaten is set separately, on the card.
struct NutritionEditor: View {
    @Binding var nutrition: Nutrition
    @Binding var servingSize: Double
    let unit: ServingUnit
    var showsExtendedFields: Bool = false

    @State private var showsMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Label values per")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                NumericEntryField(title: "Serving size", value: $servingSize,
                                  unitLabel: unit.shortLabel, showsTitle: false)
                    .frame(width: 96)
                Spacer(minLength: 0)
            }

            let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                NumericEntryField(title: "Calories", value: $nutrition.calories,
                                  unitLabel: "kcal")
                NumericEntryField(title: "Protein", value: $nutrition.protein, unitLabel: "g")
                NumericEntryField(title: "Carbs", value: $nutrition.carbs, unitLabel: "g")
                NumericEntryField(title: "Fat", value: $nutrition.fat, unitLabel: "g")
                NumericEntryField(title: "Fibre", value: $nutrition.fibre, unitLabel: "g")
                if showsExtendedFields && showsMore {
                    NumericEntryField(title: "Sugar", value: $nutrition.sugar, unitLabel: "g")
                    NumericEntryField(title: "Sodium", value: $nutrition.sodium, unitLabel: "mg")
                }
            }

            if showsExtendedFields {
                Button(showsMore ? "Fewer nutrients" : "Sugar and sodium") {
                    withAnimation(.snappy) { showsMore.toggle() }
                }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
            }
        }
        // Open automatically if a scanned label already filled them in.
        .onAppear { if nutrition.sugar > 0 || nutrition.sodium > 0 { showsMore = true } }
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
                .tint(AppTheme.nativeSlider)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

// MARK: - Keyboard

extension View {
    /// Sliding the page down closes the keyboard. Taps outside a text field
    /// close it too, via `TapToDismissKeyboard` installed once at the root.
    /// There is deliberately no "Done" bar above the keyboard: it slid in and
    /// out with the keyboard and made closing it jumpy.
    func keyboardDismissControls() -> some View {
        self.scrollDismissesKeyboard(.interactively)
    }
}

/// Closes whatever keyboard is open, wherever the focused field is.
@MainActor
func dismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
    #endif
}

#if canImport(UIKit)
/// Closes the keyboard when the user taps anywhere that isn't a text field.
///
/// Installed once as a background of the root view. It adds one tap recogniser
/// to the app's window, which also covers sheets and full-screen covers. The
/// recogniser never cancels touches, so buttons, steppers and menus still work
/// normally. Taps on another text field are ignored, so moving between fields
/// keeps the keyboard up instead of closing and reopening it. The keyboard
/// itself lives in a separate window, so typing is never interrupted.
struct TapToDismissKeyboard: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private var recogniser: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, window !== installedWindow else { return }
            if let recogniser { installedWindow?.removeGestureRecognizer(recogniser) }

            let tap = UITapGestureRecognizer(target: self, action: #selector(closeKeyboard))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recogniser = tap
            installedWindow = window
        }

        @objc private func closeKeyboard() {
            installedWindow?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

// MARK: - Text input box

extension View {
    /// Draws a text field as a visible box - fill plus a hairline border - so
    /// it reads as something to type into rather than a plain label.
    /// `fill` lets a field sit on a card or on a tinted row with enough contrast.
    func inputBox(fill: Color = AppTheme.subtleFill) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Training days

/// Strength and cardio days per week. They share one week, so together they
/// can't exceed 7: raising one lowers the other when needed, and the remaining
/// rest days are shown underneath.
///
/// Stored for profile context only - the activity level already covers the
/// calories (spec section 6) - but the numbers should still make sense.
struct TrainingDaysEditor: View {
    @Binding var strengthDays: Int
    @Binding var cardioDays: Int

    static let daysInWeek = 7

    private var restDays: Int { max(0, Self.daysInWeek - strengthDays - cardioDays) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SliderEntryRow(title: "Strength training days per week",
                           value: binding(for: $strengthDays, other: $cardioDays),
                           range: 0...Double(Self.daysInWeek), step: 1)
            SliderEntryRow(title: "Cardio days per week",
                           value: binding(for: $cardioDays, other: $strengthDays),
                           range: 0...Double(Self.daysInWeek), step: 1)
            Text(restDays == 1 ? "1 rest day a week" : "\(restDays) rest days a week")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            // Earlier versions allowed up to 14 of each; bring old values in line.
            let fixed = Self.normalised(strength: strengthDays, cardio: cardioDays)
            if fixed.strength != strengthDays { strengthDays = fixed.strength }
            if fixed.cardio != cardioDays { cardioDays = fixed.cardio }
        }
    }

    private func binding(for value: Binding<Int>, other: Binding<Int>) -> Binding<Double> {
        Binding(
            get: { Double(min(max(value.wrappedValue, 0), Self.daysInWeek)) },
            set: { newValue in
                let adjusted = Self.adjust(changed: Int(newValue.rounded()), other: other.wrappedValue)
                value.wrappedValue = adjusted.changed
                if adjusted.other != other.wrappedValue { other.wrappedValue = adjusted.other }
            })
    }

    /// The value just changed wins; the other gives way so the week isn't
    /// over-full.
    static func adjust(changed: Int, other: Int) -> (changed: Int, other: Int) {
        let changed = min(max(changed, 0), daysInWeek)
        return (changed, min(max(other, 0), daysInWeek - changed))
    }

    /// Fixes stored values from before the 7-day rule, keeping their proportion.
    static func normalised(strength: Int, cardio: Int) -> (strength: Int, cardio: Int) {
        let s = min(max(strength, 0), daysInWeek)
        let c = min(max(cardio, 0), daysInWeek)
        guard s + c > daysInWeek else { return (s, c) }
        let scaledStrength = Int((Double(s) / Double(s + c) * Double(daysInWeek)).rounded())
        return (scaledStrength, daysInWeek - scaledStrength)
    }
}
