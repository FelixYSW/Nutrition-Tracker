import Foundation

/// Editable, non-persisted representation of a food about to be saved.
///
/// Every path into the database goes through a draft - manual entry, the photo
/// pipeline, barcode lookup and the assistant - so the mandatory review step
/// has exactly one implementation (spec sections 12, 18, 28, 29A).
struct FoodEntryDraft: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var consumedAt: Date = .now
    var quantity: Double = 1
    var servingSize: Double = 1
    var unit: ServingUnit = .serving
    /// Used only when `ingredients` is empty (a simple food).
    var nutritionPerServing: Nutrition = .zero
    var ingredients: [IngredientDraft] = []
    var source: FoodSource = .manual
    var photoPath: String?
    var barcode: String?
    var canonicalID: String?
    /// Carried through from the photo pipeline so the review UI can show it.
    var confidence: Double?
    /// The pipeline's raw `PhotoAnalysisResult`, JSON-encoded, kept so the
    /// user's confirmed version can be paired with it as a correction record
    /// (spec section 24). Never persisted on the entry itself.
    var predictionJSON: Data?

    var isComposite: Bool { !ingredients.isEmpty }

    var nutritionForOneServing: Nutrition {
        isComposite ? ingredients.reduce(.zero) { $0 + $1.total } : nutritionPerServing
    }

    var total: Nutrition {
        nutritionForOneServing * NutritionMath.scaleFactor(quantity: quantity,
                                                           servingSize: servingSize)
    }

    /// A draft is saveable once it has a name and some actual nutrition. An
    /// all-zero entry is almost always an accident.
    var isSaveable: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard quantity > 0 else { return false }
        return total.calories > 0 || total.protein > 0 || total.carbs > 0 || total.fat > 0
    }

    var hasLowConfidenceItems: Bool {
        if let confidence, confidence < NutritionConstants.lowConfidenceThreshold { return true }
        return ingredients.contains(where: \.isLowConfidence)
    }

    // MARK: Conversion

    func makeEntry() -> FoodEntry {
        FoodEntry(id: id,
                  name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                  consumedAt: consumedAt,
                  quantity: quantity,
                  servingSize: servingSize,
                  unit: unit,
                  nutritionPerServing: nutritionPerServing.sanitised,
                  ingredients: ingredients.enumerated().map { index, draft in
                      let item = draft.makeItem()
                      item.position = index
                      return item
                  },
                  source: source,
                  photoPath: photoPath,
                  barcode: barcode)
    }

    init(id: UUID = UUID(), name: String = "", consumedAt: Date = .now,
         quantity: Double = 1, servingSize: Double = 1, unit: ServingUnit = .serving,
         nutritionPerServing: Nutrition = .zero, ingredients: [IngredientDraft] = [],
         source: FoodSource = .manual, photoPath: String? = nil,
         barcode: String? = nil, canonicalID: String? = nil, confidence: Double? = nil) {
        self.id = id
        self.name = name
        self.consumedAt = consumedAt
        self.quantity = quantity
        self.servingSize = servingSize
        self.unit = unit
        self.nutritionPerServing = nutritionPerServing
        self.ingredients = ingredients
        self.source = source
        self.photoPath = photoPath
        self.barcode = barcode
        self.canonicalID = canonicalID
        self.confidence = confidence
    }

    /// Round-trips an existing entry into an editable draft.
    init(entry: FoodEntry) {
        self.id = entry.id
        self.name = entry.name
        self.consumedAt = entry.consumedAt
        self.quantity = entry.quantity
        self.servingSize = entry.servingSize
        self.unit = entry.unit
        self.nutritionPerServing = entry.nutritionPerServing
        self.ingredients = entry.orderedIngredients.map(IngredientDraft.init(item:))
        self.source = entry.source
        self.photoPath = entry.photoPath
        self.barcode = entry.barcode
    }

    /// Writes the draft back onto a persisted entry, reusing ingredient rows
    /// where the identifier still matches so SwiftData does not churn objects.
    func apply(to entry: FoodEntry) {
        entry.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.consumedAt = consumedAt
        entry.quantity = quantity
        entry.servingSize = servingSize
        entry.unit = unit
        entry.nutritionPerServing = nutritionPerServing.sanitised
        entry.source = source
        entry.photoPath = photoPath
        entry.barcode = barcode

        var existing = Dictionary(uniqueKeysWithValues: entry.ingredients.map { ($0.id, $0) })
        var rebuilt: [IngredientItem] = []
        for (index, draft) in ingredients.enumerated() {
            let item: IngredientItem
            if let reused = existing.removeValue(forKey: draft.id) {
                draft.apply(to: reused)
                item = reused
            } else {
                item = draft.makeItem()
            }
            item.position = index
            rebuilt.append(item)
        }
        entry.ingredients = rebuilt
        entry.touch()
    }
}

struct IngredientDraft: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var quantity: Double = 1
    var servingSize: Double = 1
    var unit: ServingUnit = .gram
    var nutritionPerServing: Nutrition = .zero
    var confidence: Double?
    var canonicalID: String?
    /// Where the numbers came from, shown in the review UI so the user knows
    /// which rows are lab-measured and which are a model estimate.
    var provenance: NutritionProvenance = .manual

    var total: Nutrition {
        nutritionPerServing * NutritionMath.scaleFactor(quantity: quantity,
                                                        servingSize: servingSize)
    }

    var isLowConfidence: Bool {
        guard let confidence else { return false }
        return confidence < NutritionConstants.lowConfidenceThreshold
    }

    func makeItem() -> IngredientItem {
        IngredientItem(id: id,
                       name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                       quantity: quantity,
                       servingSize: servingSize,
                       unit: unit,
                       nutritionPerServing: nutritionPerServing.sanitised,
                       confidence: confidence,
                       canonicalID: canonicalID)
    }

    func apply(to item: IngredientItem) {
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.quantity = quantity
        item.servingSize = servingSize
        item.unit = unit
        item.nutritionPerServing = nutritionPerServing.sanitised
        item.confidence = confidence
        item.canonicalID = canonicalID
    }

    init(id: UUID = UUID(), name: String = "", quantity: Double = 1,
         servingSize: Double = 1, unit: ServingUnit = .gram,
         nutritionPerServing: Nutrition = .zero, confidence: Double? = nil,
         canonicalID: String? = nil, provenance: NutritionProvenance = .manual) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.servingSize = servingSize
        self.unit = unit
        self.nutritionPerServing = nutritionPerServing
        self.confidence = confidence
        self.canonicalID = canonicalID
        self.provenance = provenance
    }

    init(item: IngredientItem) {
        self.id = item.id
        self.name = item.name
        self.quantity = item.quantity
        self.servingSize = item.servingSize
        self.unit = item.unit
        self.nutritionPerServing = item.nutritionPerServing
        self.confidence = item.confidence
        self.canonicalID = item.canonicalID
        self.provenance = item.canonicalID == nil ? .manual : .myFCD
    }
}

/// Which tier of the nutrition data layer produced a set of numbers
/// (spec section 23). Surfaced in the UI so an estimate is never mistaken for a
/// measured value.
enum NutritionProvenance: String, Codable, Equatable, Sendable {
    case manual
    case localVerified
    case barcode
    case myFCD
    case genericDatabase
    case modelEstimate

    var displayName: String {
        switch self {
        case .manual: "Entered by you"
        case .localVerified: "Your saved food"
        case .barcode: "Product label"
        case .myFCD: "MyFCD"
        case .genericDatabase: "Generic database"
        case .modelEstimate: "AI estimate"
        }
    }

    /// True where the figures are an estimate rather than a measured or
    /// label-declared value.
    var isEstimate: Bool {
        self == .modelEstimate
    }
}
