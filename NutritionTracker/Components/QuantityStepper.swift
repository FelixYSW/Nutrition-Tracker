import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Minus/plus control for a quantity (spec section 11), with the number in its
/// own box that can be tapped and typed into. The unit is not shown here: it
/// sits beside the stepper in a `UnitPicker`, so each can be changed on its own.
///
/// Changing the quantity only ever recalculates locally - it never re-runs the
/// AI pipeline or hits the network, so a +/- press is instant.
///
/// When a minus press reaches zero the control reports it via `onReachedZero`
/// so the owning view can offer removal, rather than leaving a zero-quantity row.
/// Typing zero or clearing the box is ignored instead: it's usually mid-edit.
struct QuantityStepper: View {
    @Binding var quantity: Double
    let unit: ServingUnit

    /// Called when a decrement would take the value to zero or below.
    var onReachedZero: (() -> Void)?

    @State private var text = ""
    @FocusState private var isEditing: Bool

    private var step: Double { unit.step }

    var body: some View {
        HStack(spacing: 2) {
            button(symbol: "minus", label: "Decrease", enabled: quantity > 0) {
                decrement()
            }

            TextField("0", text: $text)
                .keyboardType(unit.fractionDigits > 0 ? .decimalPad : .numberPad)
                .multilineTextAlignment(.center)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .focused($isEditing)
                .frame(width: 58, height: 32)
                .background(AppTheme.cardBackground,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(isEditing ? 0.6 : 0.25), lineWidth: 1))
                .accessibilityLabel("Amount in \(unit.displayName)")
                .onChange(of: text) { _, newValue in
                    // Live update while typing, but only for usable values.
                    guard isEditing else { return }
                    let parsed = NumericEntryField.parse(newValue)
                    if parsed > 0 { quantity = parsed }
                }
                .onChange(of: isEditing) { _, editing in
                    if !editing { syncText() }
                }

            button(symbol: "plus", label: "Increase", enabled: true) {
                increment()
            }
        }
        .padding(.horizontal, 2)
        .background(AppTheme.subtleFill, in: Capsule())
        .fixedSize()
        .onAppear { syncText() }
        .onChange(of: quantity) { _, _ in
            if !isEditing { syncText() }
        }
        .onChange(of: unit) { _, _ in syncText() }
    }

    private func syncText() {
        text = quantity > 0 ? AppFormatters.quantity(quantity, unit: unit) : ""
    }

    private func button(symbol: String, label: String,
                        enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                // Narrower than 44pt so the row fits on small phones; the full
                // capsule height keeps it easy to hit.
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? AppTheme.accent : Color.secondary)
        .accessibilityLabel(label)
    }

    private func increment() {
        isEditing = false
        quantity = Self.rounded(quantity + step, unit: unit)
        Haptics.selection()
    }

    private func decrement() {
        isEditing = false
        let next = Self.rounded(quantity - step, unit: unit)
        if next <= 0 {
            quantity = 0
            Haptics.warning()
            onReachedZero?()
        } else {
            quantity = next
            Haptics.selection()
        }
    }

    /// Keeps the value on clean step boundaries so repeated presses do not
    /// accumulate floating-point noise (e.g. 0.30000000000000004 scoops).
    static func rounded(_ value: Double, unit: ServingUnit) -> Double {
        guard value.isFinite else { return 0 }
        let step = unit.step
        guard step > 0 else { return max(0, value) }
        let steps = (value / step).rounded()
        return max(0, (steps * step * 1000).rounded() / 1000)
    }
}

/// Thin wrapper so haptics are a one-liner at call sites and a no-op off-device.
enum Haptics {
    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func error() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

/// Compact unit menu shown beside a `QuantityStepper`: "g", "ml", "pc"...
/// Sized to its label so it never pushes the row onto two lines.
struct UnitPicker: View {
    @Binding var unit: ServingUnit

    var body: some View {
        Menu {
            Picker("Unit", selection: $unit) {
                ForEach(ServingUnit.allCases) { Text($0.displayName).tag($0) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(unit.shortLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 52, minHeight: 36)
            .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .fixedSize()
        .accessibilityLabel("Unit")
        .accessibilityValue(unit.displayName)
    }
}
