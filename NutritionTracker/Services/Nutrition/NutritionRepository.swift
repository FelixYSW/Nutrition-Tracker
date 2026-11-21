import Foundation
import SwiftData

/// Turns the photo models' output into per-ingredient nutrition.
///
/// There is no food table in the app any more: figures come from the user
/// (labels, foods logged before), the assistant's estimates and brand
/// lookups, or - for photos - the portion model's whole-plate estimate,
/// split here across the foods it found. Final arithmetic happens in Swift.
@MainActor
final class NutritionRepository {

    init(context: ModelContext) {}

    /// Splits Model B's whole-plate prediction across Model A's foods by their
    /// share of the mass. Without a plate prediction every food is left at
    /// zero for the user (or the assistant) to fill in.
    func resolve(detections: [DetectedIngredient],
                 portions: [PortionEstimate],
                 wholePlateNutrition: Nutrition?) -> [ResolvedIngredientNutrition] {

        let massByDetection = Dictionary(
            portions.map { ($0.detectionID, $0.estimatedGrams) },
            uniquingKeysWith: { first, _ in first }
        )

        var resolved = detections.map { detection in
            ResolvedIngredientNutrition(
                detectionID: detection.id,
                displayName: detection.displayName,
                canonicalID: detection.canonicalID,
                grams: massByDetection[detection.id] ?? 0,
                nutritionPer100g: .zero,
                provenance: .modelEstimate,
                confidence: detection.confidence)
        }
        guard !resolved.isEmpty, let plate = wholePlateNutrition else { return resolved }

        let totalMass = resolved.map(\.grams).reduce(0, +)
        for index in resolved.indices {
            let grams = resolved[index].grams
            let share = totalMass > 0 ? grams / totalMass : 1.0 / Double(resolved.count)
            // Per 100 g, so the row scales when the user changes the amount.
            let per100 = grams > 0 ? plate * share * (100 / grams) : .zero
            resolved[index].nutritionPer100g = per100.sanitised
        }
        return resolved
    }
}
