import Foundation

struct IngredientDraft: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var quantity = 1.0
    var servingSize = 1.0
    var unit: ServingUnit = .serving
    var nutrition: Nutrition = .zero
    var confidence: Double?
    var canonicalID: String?
    var total: Nutrition { nutrition * (quantity / max(servingSize, 0.0001)) }
    func model() -> IngredientItem {
        IngredientItem(id: id, name: name, quantity: quantity, servingSize: servingSize,
                       unit: unit, nutrition: nutrition, confidence: confidence, canonicalID: canonicalID)
    }
}

struct FoodDraft: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var consumedAt = Date()
    var quantity = 1.0
    var servingSize = 1.0
    var unit: ServingUnit = .serving
    var nutrition: Nutrition = .zero
    var ingredients: [IngredientDraft] = []
    var source: FoodSource = .manual
    var photoPath: String?
    var barcode: String?
    var total: Nutrition {
        let base = ingredients.isEmpty ? nutrition : ingredients.reduce(.zero) { $0 + $1.total }
        return base * (quantity / max(servingSize, 0.0001))
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quantity > 0 &&
        servingSize > 0 && nutrition.isValid && ingredients.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.quantity > 0 && $0.servingSize > 0 && $0.nutrition.isValid
        }
    }
    init() {}
    init(_ entry: FoodEntry) {
        id = entry.id; name = entry.name; consumedAt = entry.consumedAt
        quantity = entry.quantity; servingSize = entry.servingSize; unit = entry.unit
        nutrition = entry.nutrition; source = entry.source; photoPath = entry.photoPath
        barcode = entry.barcode
        ingredients = entry.ingredients.map { item in
            IngredientDraft(id: item.id, name: item.name, quantity: item.quantity,
                            servingSize: item.servingSize, unit: item.unit, nutrition: item.nutrition,
                            confidence: item.confidence, canonicalID: item.canonicalID)
        }
    }
    func model() -> FoodEntry {
        FoodEntry(id: id, name: name, consumedAt: consumedAt, quantity: quantity,
                  servingSize: servingSize, unit: unit, nutrition: nutrition,
                  ingredients: ingredients.map { $0.model() }, source: source,
                  photoPath: photoPath, barcode: barcode)
    }
}

@MainActor @Observable final class DraftStore {
    var drafts: [FoodDraft] = [FoodDraft()]
    var selectedTab = 0
    var aiOriginal: Data?
    var pendingImage: Data?
    var editingID: UUID?
    var canRemoveFood: Bool { drafts.count > 1 }
    func remove(_ id: UUID) {
        guard canRemoveFood else { return }
        drafts.removeAll { $0.id == id }
    }
    func reset() {
        drafts = [FoodDraft()]
        aiOriginal = nil; pendingImage = nil; editingID = nil
    }
    func load(_ draft: FoodDraft) { editingID = nil; drafts = [draft]; selectedTab = 2 }
    func edit(_ entry: FoodEntry) { load(FoodDraft(entry)); editingID = entry.id }
}
