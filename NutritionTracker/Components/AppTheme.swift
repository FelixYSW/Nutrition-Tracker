import SwiftUI

/// Visual language for the app.
///
/// Everything resolves through semantic system colours so light and dark mode
/// both work without a second palette, and so the app inherits the user's
/// contrast and tint settings (spec section 33).
enum AppTheme {

    // MARK: Colours

    static let accent = Color.accentColor

    static var background: Color { Color(.systemGroupedBackground) }
    static var cardBackground: Color { Color(.secondarySystemGroupedBackground) }
    static var subtleFill: Color { Color(.tertiarySystemFill) }

    /// Per-nutrient ring colours. Distinct in hue *and* order so they remain
    /// distinguishable for the common forms of colour vision deficiency; the
    /// rings are also always labelled, never colour-only.
    static func color(for nutrient: Nutrient) -> Color {
        switch nutrient {
        case .calories: Color(red: 0.98, green: 0.45, blue: 0.21)
        case .protein: Color(red: 0.23, green: 0.52, blue: 0.96)
        case .carbs: Color(red: 0.96, green: 0.70, blue: 0.14)
        case .fat: Color(red: 0.60, green: 0.40, blue: 0.90)
        case .fibre: Color(red: 0.18, green: 0.70, blue: 0.52)
        }
    }

    /// Colour for a range state.
    ///
    /// `under` deliberately keeps the nutrient's own colour: being under the
    /// band is the normal state for most of the day and must not read as an
    /// error. Only `over` gets a warning treatment.
    static func color(for state: RangeState, nutrient: Nutrient) -> Color {
        switch state {
        case .under: color(for: nutrient)
        case .within: Color(red: 0.16, green: 0.68, blue: 0.45)
        case .over: Color(red: 0.90, green: 0.49, blue: 0.13)
        }
    }

    // MARK: Metrics

    static let cornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 16
    static let pageSpacing: CGFloat = 20
    /// Minimum tappable edge, per Apple's 44pt guidance.
    static let minimumTapTarget: CGFloat = 44
}

// MARK: - Layout modifiers

private struct AppCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppTheme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardBackground, in: RoundedRectangle(
                cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

private struct AppPageContent: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Horizontal padding only: the content still spans the full device
            // width, with a consistent gutter rather than a fixed-width column.
            .padding(.horizontal, AppTheme.cardPadding)
            .padding(.vertical, AppTheme.pageSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func appCard() -> some View { modifier(AppCard()) }
    func appPageContent() -> some View { modifier(AppPageContent()) }

    /// Full-bleed page background that extends under the safe areas.
    func appPageSurface() -> some View {
        self.background(AppTheme.background.ignoresSafeArea())
    }
}

// MARK: - Small shared views

struct AppSectionHeading: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The disclaimer required wherever estimated nutrition is shown
/// (spec sections 1, 18, 28).
struct EstimateDisclaimer: View {
    var text = "Nutrition and portions are estimates. Review before saving."

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
