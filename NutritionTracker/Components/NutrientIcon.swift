import SwiftUI

/// A nutrient's icon wherever one is shown, from Lucide (lucide.dev, ISC
/// licence - see LICENSE-lucide.txt): flame for calories, a flexed arm for
/// protein, wheat for carbs, a droplet for fat and a leaf for fibre.
///
/// The icons are vector template images in the asset catalogue, so they
/// take the foreground colour like a symbol and stay sharp at any size.
struct NutrientIcon: View {
    let nutrient: Nutrient
    /// The point size a symbol would be drawn at beside the same text.
    var size: CGFloat = 16

    var body: some View {
        nutrient.icon
            .resizable()
            .scaledToFit()
            // Lucide's line icons sit inside a 24-unit box with padding, so
            // they are drawn a little larger to match a symbol's weight.
            .frame(width: size * 1.2, height: size * 1.2)
            .accessibilityHidden(true)
    }
}

extension Nutrient {
    /// The icon as an image, for menus and anywhere else an `Image` is needed.
    var icon: Image {
        Image(assetName).renderingMode(.template)
    }

    private var assetName: String {
        switch self {
        case .calories: "NutrientCalories"
        case .protein: "NutrientProtein"
        case .carbs: "NutrientCarbs"
        case .fat: "NutrientFat"
        case .fibre: "NutrientFibre"
        }
    }
}
