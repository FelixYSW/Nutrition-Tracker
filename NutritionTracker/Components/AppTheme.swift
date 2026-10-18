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
    /// Exception: the slider fill is the ink, as in the mockups. It is still
    /// the native Slider, only tinted.
    static var nativeSlider: Color { accentFill }

    /// Page background: warm paper / soft charcoal.
    static var background: Color { .adaptive(light: 0xF3F1EC, dark: 0x1B1A18) }
    /// Cards sit one step lighter (light) or lighter-grey (dark) than the page.
    static var cardBackground: Color { .adaptive(light: 0xFAF9F6, dark: 0x252421) }
    static var subtleFill: Color { .adaptive(light: 0xE6E3DC, dark: 0x33312D) }
    /// Hairline round cards, so they separate from the page without a shadow.
    static var cardBorder: Color { .adaptive(light: 0xECE9E2, dark: 0x33312D) }

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

    /// The flame orange from the app icon. Used for calories wherever they are
    /// shown, so the number and the icon read as one thing.
    static let flame = Color(hex: 0xDB5A1F)

    /// Text for destructive actions ("Delete all data"): a warm brick red
    /// that keeps 4.5:1 contrast, instead of the system's bright red.
    static var destructiveText: Color { .adaptive(light: 0xA8351C, dark: 0xF08A70) }

    /// Per-nutrient ring colours. Distinct in hue *and* order so they remain
    /// distinguishable for the common forms of colour vision deficiency; the
    /// rings are also always labelled, never colour-only.
    static func color(for nutrient: Nutrient) -> Color {
        switch nutrient {
        case .calories: flame
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

    /// Darker (light mode) or lighter (dark mode) shade of a nutrient colour
    /// for text, such as tile labels. The ring colours themselves fall below
    /// 4.5:1 contrast as small text on the paper and their own tints.
    static func textColor(for nutrient: Nutrient) -> Color {
        switch nutrient {
        case .calories: .adaptive(light: 0xB0441A, dark: 0xF2956A)
        case .protein: .adaptive(light: 0x0B6B6D, dark: 0x5CC8CA)
        case .carbs: .adaptive(light: 0x855F06, dark: 0xE2B850)
        case .fat: .adaptive(light: 0x6A40C0, dark: 0xB9A0F2)
        case .fibre: .adaptive(light: 0xA81E50, dark: 0xF07FA6)
        }
    }

    /// Readable text for a state on its tinted pill: ink while under (which
    /// is neutral), a deep green in range, a deep orange over.
    static func stateTextColor(for state: RangeState) -> Color {
        switch state {
        case .under: ink
        case .within: .adaptive(light: 0x2E6A44, dark: 0x9FD4B0)
        case .over: .adaptive(light: 0xA4501B, dark: 0xF0A468)
        }
    }

    /// Background for a status pill.
    static func stateFill(for state: RangeState) -> Color {
        switch state {
        case .under: subtleFill
        case .within: within.opacity(0.16)
        case .over: over.opacity(0.16)
        }
    }

    /// Neutral grey for "under" while the day is still going.
    static var stillToGo: Color { .adaptive(light: 0xC2BEB6, dark: 0x58554F) }

    /// Colour for a bar or dot that summarises a day, week or month against its
    /// band. Under the minimum is a neutral grey.
    static func summaryColor(for state: RangeState, isComplete: Bool = true) -> Color {
        switch state {
        // Under is neutral grey whether or not the period is over; only
        // "within" and "over" get a colour of their own.
        case .under: stillToGo
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
        func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }
        UINavigationBar.appearance().titleTextAttributes = [
            .foregroundColor: ink, .font: rounded(17, .bold)]
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .foregroundColor: ink, .font: rounded(32, .heavy)]
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
            .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.cardBorder, lineWidth: 1))
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
            // Exactly as wide as the page's scroll view. Without this, one
            // child wider than the screen made the whole page wider, and the
            // vertical scroll view then let it be dragged sideways.
            .containerRelativeFrame(.horizontal, alignment: .leading)
    }
}

extension View {
    func appCard() -> some View { modifier(AppCard()) }
    func appSkyCard() -> some View { modifier(AppSkyCard()) }
    func appPageContent() -> some View { modifier(AppPageContent()) }

    /// Full-bleed page background that extends under the safe areas.
    func appPageSurface() -> some View {
        self.background(AppTheme.background.ignoresSafeArea())
            .verticalScrollingOnly()
    }

    /// Pages scroll up and down only: no sideways rubber-banding unless the
    /// content genuinely is wider than the screen.
    func verticalScrollingOnly() -> some View {
        scrollBounceBehavior(.basedOnSize, axes: .horizontal)
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
            .overlay(shape.stroke(Color(hex: 0xF6F4EF).opacity(0.45), lineWidth: 0.75))
            .shadow(color: Color(hex: 0x2A2926).opacity(0.12), radius: 14, y: 6)
    }
}

// MARK: - Button styles

/// Filled sky-blue capsule with dark text.
struct PrimaryButtonStyle: ButtonStyle {
    /// Fill colour: the ink by default; a destructive confirmation passes red.
    var fill: Color = AppTheme.accentFill
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.heavy))
            .foregroundStyle(isEnabled ? AppTheme.onAccent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 20)
            // Solid in both states. Fading the fill to show "disabled" made
            // the content behind the button show through it.
            .background(isEnabled ? fill : AppTheme.subtleFill, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
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

// MARK: - Nutrient symbols

extension Nutrient {
    /// SF Symbol used wherever a nutrient needs an icon (rings, summary
    /// tiles). System symbols, so they follow Dynamic Type and the user's
    /// weight settings.
    var symbolName: String {
        switch self {
        case .calories: "flame.fill"
        case .protein: "dumbbell.fill"
        case .carbs: "fork.knife"
        case .fat: "drop.fill"
        case .fibre: "leaf.fill"
        }
    }
}

// MARK: - Logo

/// The app icon's mark: a partly filled progress ring around a flame.
/// Drawn with system shapes and the flame SF Symbol, so it scales cleanly and
/// follows light and dark mode.
struct AppLogoMark: View {
    var size: CGFloat = 120
    /// How far round the ring is filled. The icon leaves it open.
    var progress: Double = 0.72

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.ink.opacity(0.1), lineWidth: size * 0.082)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AppTheme.ink,
                        style: StrokeStyle(lineWidth: size * 0.082, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "flame.fill")
                .font(.system(size: size * 0.34))
                .foregroundStyle(AppTheme.flame)
        }
        .padding(size * 0.041)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Appearance

/// Light or dark, or follow the system. Light is the default: the warm paper
/// palette, with no pure white or pure black anywhere.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    /// Like `colorScheme`, but "System" becomes the phone's actual setting
    /// instead of nil. For sheets: going back to nil while a sheet is open
    /// leaves it stuck in the previous scheme until it is reopened.
    var resolvedColorScheme: ColorScheme {
        if let colorScheme { return colorScheme }
        #if canImport(UIKit)
        return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        #else
        return .light
        #endif
    }
}
