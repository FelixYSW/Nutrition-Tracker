import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Minus/plus control for a quantity (spec section 11).
///
/// Changing the quantity only ever recalculates locally - it never re-runs the
/// AI pipeline or hits the network, so a +/- press is instant.
///
/// When the value reaches zero the control reports it via `onReachedZero` so the
/// owning view can offer removal, rather than leaving a zero-quantity row.
struct QuantityStepper: View {
    @Binding var quantity: Double
    let unit: ServingUnit

    /// Called when a decrement would take the value to zero or below.
    var onReachedZero: (() -> Void)?

    private var step: Double { unit.step }

    var body: some View {
        HStack(spacing: 0) {
            button(symbol: "minus", label: "Decrease", enabled: quantity > 0) {
                decrement()
            }

            Text("\(AppFormatters.quantity(quantity, unit: unit)) \(unit.shortLabel)")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 72)
                .padding(.horizontal, 4)
                .contentTransition(.numericText())

            button(symbol: "plus", label: "Increase", enabled: true) {
                increment()
            }
        }
        .padding(.horizontal, 4)
        .background(AppTheme.subtleFill, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quantity")
        .accessibilityValue("\(AppFormatters.quantity(quantity, unit: unit)) \(unit.displayName)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement()
            default: break
            }
        }
    }

    private func button(symbol: String, label: String,
                        enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .frame(width: AppTheme.minimumTapTarget,
                       height: AppTheme.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? AppTheme.accent : Color.secondary)
        .accessibilityLabel(label)
    }

    private func increment() {
        quantity = Self.rounded(quantity + step, unit: unit)
        Haptics.selection()
    }

    private func decrement() {
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
