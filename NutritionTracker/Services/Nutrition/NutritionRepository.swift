import Foundation
import SwiftData

/// A nutrition lookup result, tagged with where it came from.
struct NutritionLookupResult: Equatable, Sendable {
    var canonicalID: String?
    var displayName: String
    /// Per 100 g, which is how both reference tables store their figures.
    var nutritionPer100g: Nutrition
    var provenance: NutritionProvenance
}

/// Nutrition data layer (spec section 23).
///
/// Lookup order, first hit wins:
///   1. Locally verified / personal cached food (including user-entered barcodes)
///   2. Barcode / manufacturer data (Open Food Facts) where a barcode applies
///   3. MyFCD - the Malaysian Ministry of Health's lab-measured database -
///      as the canonical generic source for local dishes
///   4. A generic international table for non-Malaysian foods absent from MyFCD
///   5. Model B's estimate, as a last resort
///
/// Final arithmetic always happens in Swift; a model prediction is never the
/// primary source when a canonical match exists.
protocol NutritionProviding: Sendable {
    func lookup(canonicalID: String?, name: String) async -> NutritionLookupResult?
}

@MainActor
final class NutritionRepository {

    private let localTable: LocalNutritionReference
    private let ontology: FoodOntology
    private let context: ModelContext

    init(context: ModelContext,
         localTable: LocalNutritionReference = .shared,
         ontology: FoodOntology = .shared) {
        self.context = context
        self.localTable = localTable
        self.ontology = ontology
    }

    /// Tiers 1, 3 and 4. Barcode (tier 2) is handled by `BarcodeLookupService`,
    /// and tier 5 by the caller, which holds the model output.
    func lookup(canonicalID: String?, name: String) -> NutritionLookupResult? {
        // Tier 1: a food the user has already verified locally.
        if let local = lookupUserVerified(name: name) {
            return local
        }

        // Tiers 3 and 4: the bundled reference table, which is MyFCD-sourced for
        // Malaysian foods and generic for the rest. Each row carries its own
        // provenance, so the UI can say which it was.
        if let canonicalID, let row = localTable.row(canonicalID: canonicalID) {
            return row.asLookupResult()
        }

        // Fall back to resolving the name through the ontology before giving up:
        // a manually typed "nasi lemak" should still find the MyFCD row.
        if let entry = ontology.resolve(rawLabel: name),
           let row = localTable.row(canonicalID: entry.canonicalID) {
            return row.asLookupResult()
        }

        return nil
    }

    /// Tier 1. A product the user typed in themselves is treated as verified and
    /// outranks any generic table.
    private func lookupUserVerified(name: String) -> NutritionLookupResult? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let descriptor = FetchDescriptor<BarcodeProductCache>(
            predicate: #Predicate { $0.isUserEntered == true }
        )
        guard let matches = try? context.fetch(descriptor) else { return nil }
        guard let match = matches.first(where: { $0.name.lowercased() == trimmed }) else {
            return nil
        }

        // Cached products store nutrition per their own serving size; normalise
        // to per-100g so every tier returns the same shape.
        let factor = match.servingSize > 0 ? 100 / match.servingSize : 1
        return NutritionLookupResult(canonicalID: nil,
                                     displayName: match.name,
                                     nutritionPer100g: match.nutritionPerServing * factor,
                                     provenance: .localVerified)
    }

    /// Joins Model A detections and Model B masses to real nutrition figures.
    ///
    /// Where a canonical match exists the numbers come from the reference table
    /// and the model mass only sets the portion. Where it does not, Model B's
    /// whole-plate prediction is apportioned by mass as the last-resort tier.
    func resolve(detections: [DetectedIngredient],
                 portions: [PortionEstimate],
                 wholePlateNutrition: Nutrition?) -> [ResolvedIngredientNutrition] {

        let massByDetection = Dictionary(
            portions.map { ($0.detectionID, $0.estimatedGrams) },
            uniquingKeysWith: { first, _ in first }
        )

        var resolved: [ResolvedIngredientNutrition] = []
        var unresolvedIndices: [Int] = []

        for detection in detections {
            let grams = massByDetection[detection.id] ?? 0

            if let hit = lookup(canonicalID: detection.canonicalID,
                                name: detection.displayName) {
                resolved.append(ResolvedIngredientNutrition(
                    detectionID: detection.id,
                    displayName: hit.displayName,
                    canonicalID: hit.canonicalID ?? detection.canonicalID,
                    grams: grams,
                    nutritionPer100g: hit.nutritionPer100g,
                    provenance: hit.provenance,
                    confidence: detection.confidence))
            } else {
                unresolvedIndices.append(resolved.count)
                resolved.append(ResolvedIngredientNutrition(
                    detectionID: detection.id,
                    displayName: detection.displayName,
                    canonicalID: detection.canonicalID,
                    grams: grams,
                    nutritionPer100g: .zero,
                    provenance: .modelEstimate,
                    confidence: detection.confidence))
            }
        }

        // Tier 5: apportion the model's whole-plate prediction across whatever
        // could not be matched, by mass share.
        if !unresolvedIndices.isEmpty, let plate = wholePlateNutrition {
            let matchedNutrition = resolved.enumerated()
                .filter { !unresolvedIndices.contains($0.offset) }
                .reduce(Nutrition.zero) { $0 + $1.element.total }

            // Only the part of the plate prediction not already explained by
            // matched ingredients is distributed, so nutrition is not
            // double-counted.
            let residual = Nutrition(
                calories: max(0, plate.calories - matchedNutrition.calories),
                protein: max(0, plate.protein - matchedNutrition.protein),
                carbs: max(0, plate.carbs - matchedNutrition.carbs),
                fat: max(0, plate.fat - matchedNutrition.fat))

            let unresolvedMass = unresolvedIndices
                .map { resolved[$0].grams }
                .reduce(0, +)

            for index in unresolvedIndices {
                let grams = resolved[index].grams
                let share = unresolvedMass > 0
                    ? grams / unresolvedMass
                    : 1.0 / Double(unresolvedIndices.count)
                let portionNutrition = residual * share
                // Store per-100g so the row scales consistently with every
                // other tier when the user adjusts the quantity.
                let per100 = grams > 0 ? portionNutrition * (100 / grams) : .zero
                resolved[index].nutritionPer100g = per100.sanitised
            }
        }

        return resolved
    }
}

// MARK: - Bundled reference table

/// The bundled nutrition reference compiled from MyFCD plus a generic fallback
/// set (spec section 23).
///
/// MyFCD has no bulk download or public API, so the entries the app needs are
/// compiled offline into `myfcd_reference.json` by `ml/scripts/compile_reference.py`
/// and shipped in the bundle. Nothing is scraped at runtime.
struct LocalNutritionReference: Sendable {

    struct Row: Codable, Equatable, Sendable {
        let canonicalID: String
        let displayName: String
        /// All figures per 100 g edible portion.
        let calories: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        var fibre: Double?
        var sugar: Double?
        var sodium: Double?
        /// "myfcd" or "generic".
        let source: String
        /// MyFCD food code, where applicable, for traceability.
        var sourceCode: String?

        var nutritionPer100g: Nutrition {
            Nutrition(calories: calories, protein: protein, carbs: carbs,
                      fat: fat, fibre: fibre ?? 0, sugar: sugar ?? 0,
                      sodium: sodium ?? 0).sanitised
        }

        var provenance: NutritionProvenance {
            source == "myfcd" ? .myFCD : .genericDatabase
        }

        func asLookupResult() -> NutritionLookupResult {
            NutritionLookupResult(canonicalID: canonicalID,
                                  displayName: displayName,
                                  nutritionPer100g: nutritionPer100g,
                                  provenance: provenance)
        }
    }

    private let rowsByCanonicalID: [String: Row]

    static let shared = LocalNutritionReference.loadBundled()

    init(rows: [Row]) {
        self.rowsByCanonicalID = Dictionary(rows.map { ($0.canonicalID, $0) },
                                            uniquingKeysWith: { first, _ in first })
    }

    static func loadBundled(bundle: Bundle = .main) -> LocalNutritionReference {
        guard let url = bundle.url(forResource: "myfcd_reference", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return LocalNutritionReference(rows: [])
        }
        return load(data: data)
    }

    static func load(data: Data) -> LocalNutritionReference {
        struct File: Codable { let version: Int; let rows: [Row] }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return LocalNutritionReference(rows: file.rows)
        } catch {
            return LocalNutritionReference(rows: [])
        }
    }

    var count: Int { rowsByCanonicalID.count }
    var isEmpty: Bool { rowsByCanonicalID.isEmpty }

    func row(canonicalID: String) -> Row? { rowsByCanonicalID[canonicalID] }

    var allRows: [Row] { Array(rowsByCanonicalID.values) }
}
