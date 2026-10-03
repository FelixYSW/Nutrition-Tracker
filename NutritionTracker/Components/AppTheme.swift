import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Visual language for the app: a calm "paper and ink" palette.
///
/// Light mode is a warm off-white with soft charcoal text; dark mode is a soft
/// charcoal with off-white text. Neither uses pure #FFFFFF or #000000: pure
/// white glares and pure black on white has harsh contrast, both of which are
/// tiring to read for long. Contrast stays well above WCAG AA (spec section 33).
///
/// The main (accent) colour is the ink itself, so the interface is monochrome
/// and colour is reserved for meaning: the nutrient rings and range states.
enum AppTheme {

    // MARK: Colours

    /// Body text and icons. Soft charcoal / soft off-white.
    static var ink: Color { .adaptive(light: inkLight, dark: inkDark) }
    static let inkLight: UInt32 = 0x2A2926
    static let inkDark: UInt32 = 0xE7E4DE

    /// Main colour for links, icons, the selected tab and primary buttons.
    static var accent: Color { ink }

    /// Fill for primary buttons and selected chips. Always paired with
    /// `onAccent` text.
    static var accentFill: Color { .adaptive(light: 0x2F2E2B, dark: 0xE2DFD8) }

    /// Text on top of `accentFill`: the paper colour, inverted per mode.
    static var onAccent: Color { .adaptive(light: 0xF6F4EF, dark: 0x1F1E1C) }

    /// Stock iOS control colours. Switches and sliders use these rather than
    /// the app accent so they look exactly like the system's own controls; an
    /// explicit tint is needed because the app-wide accent tint would
    /// otherwise recolour them.
    static var nativeSwitch: Color { Color(.systemGreen) }
    static var nativeSlider: Color { Color(.systemBlue) }

    /// Page background: warm paper / soft charcoal.
    static var background: Color { .adaptive(light: 0xF3F1EC, dark: 0x1B1A18) }
    /// Cards sit one step lighter (light) or lighter-grey (dark) than the page.
    static var cardBackground: Color { .adaptive(light: 0xFAF9F6, dark: 0x252421) }
    static var subtleFill: Color { .adaptive(light: 0xE6E3DC, dark: 0x33312D) }

    /// Tinted card used for the hero summaries.
    static var skyCard: Color { .adaptive(light: 0xEAE7E0, dark: 0x2B2A27) }
    static var skyCardText: Color { .adaptive(light: 0x55524C, dark: 0xC9C5BD) }
    /// Empty ring track on a hero card.
    static var heroTrack: Color { .adaptive(light: 0xF8F6F1, dark: 0x3A3834) }

    /// Calm green for "in range". The accent is now monochrome, so being on
    /// track gets its own colour rather than reading as plain ink.
    static var within: Color { .adaptive(light: 0x4F8A63, dark: 0x7DB892) }

    /// Warm colour for "over". Deliberately not red: going over is a heads-up,
    /// not an error.
    static var over: Color { Color(hex: 0xD9742A) }

    /// Per-nutrient ring colours. Distinct in hue *and* order so they remain
    /// distinguishable for the common forms of colour vision deficiency; the
    /// rings are also always labelled, never colour-only.
    static func color(for nutrient: Nutrient) -> Color {
        switch nutrient {
        case .calories: Color(hex: 0xF0783A)
        case .protein: Color(hex: 0x0F8B8D)
        case .carbs: Color(hex: 0xC28A0A)
        case .fat: Color(hex: 0x7A4FD0)
        case .fibre: Color(hex: 0xC2255C)
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
        case .within: within
        case .over: over
        }
    }

    /// Colour for a bar or dot that summarises a day, week or month against its
    /// band. Unlike `color(for:nutrient:)`, "under" is a neutral grey here so a
    /// calorie bar can never be mistaken for an "over" one.
    static func summaryColor(for state: RangeState) -> Color {
        switch state {
        case .under: .adaptive(light: 0xC2BEB6, dark: 0x58554F)
        case .within: within
        case .over: over
        }
    }

    // MARK: Metrics

    static let cornerRadius: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let pageSpacing: CGFloat = 18
    /// Minimum tappable edge, per Apple's 44pt guidance.
    static let minimumTapTarget: CGFloat = 44
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that follows light and dark mode without an asset catalogue.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(UIColor.adaptive(light: light, dark: dark))
        #else
        return Color(hex: light)
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    /// UIKit twin of `Color.adaptive`, for the few places UIKit draws text
    /// itself (navigation bar titles).
    static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1)
        }
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? ui(dark) : ui(light)
        }
    }
}

extension AppTheme {
    /// Navigation bar titles are drawn by UIKit, so they need the ink colour
    /// set separately or they stay pure black / pure white.
    static func applyNavigationBarTextColour() {
        let ink = UIColor.adaptive(light: inkLight, dark: inkDark)
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: ink]
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: ink]
    }
}
#endif

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

private struct AppSkyCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppTheme.cardPadding + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.skyCard, in: RoundedRectangle(
                cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

private struct AppPageContent: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Horizontal padding only: the content still spans the full device
            // width, with a consistent gutter rather than a fixed-width column.
            .padding(.horizontal, AppTheme.cardPadding + 4)
            .padding(.vertical, AppTheme.pageSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func appCard() -> some View { modifier(AppCard()) }
    func appSkyCard() -> some View { modifier(AppSkyCard()) }
    func appPageContent() -> some View { modifier(AppPageContent()) }

    /// Full-bleed page background that extends under the safe areas.
    func appPageSurface() -> some View {
        self.background(AppTheme.background.ignoresSafeArea())
    }

    /// Frosted glass for floating controls. Uses the system Liquid Glass on
    /// iOS 26 and later (when built with a new enough SDK) and a blurred
    /// material everywhere else.
    @ViewBuilder
    func appGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.appMaterial(in: shape)
        }
        #else
        self.appMaterial(in: shape)
        #endif
    }

    fileprivate func appMaterial<S: Shape>(in shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.45), lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
    }
}

// MARK: - Button styles

/// Filled sky-blue capsule with dark text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.bold))
            .foregroundStyle(AppTheme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 20)
            .background(AppTheme.accentFill.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}

/// Glass capsule with blue text, for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(minHeight: AppTheme.minimumTapTarget)
            .padding(.horizontal, 18)
            .appGlass(in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var appPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var appSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Small shared views

struct AppSectionHeading: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.bold))
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A circular, glass icon button for nav-bar-style actions on a page.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44)
                .appGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
