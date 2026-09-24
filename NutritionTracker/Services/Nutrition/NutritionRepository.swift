import Foundation

struct ReferenceFood: Codable {
    let canonicalID: String
    let name: String
    let source: String
    let per100g: Nutrition
}

protocol NutritionRepository { func food(for canonicalID: String) -> ReferenceFood? }

struct BundledNutritionRepository: NutritionRepository {
    private let foods: [String: ReferenceFood]
    init(foods: [ReferenceFood]) {
        self.foods = Dictionary(uniqueKeysWithValues: foods.map { ($0.canonicalID, $0) })
    }
    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "food_reference", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([ReferenceFood].self, from: data) else {
            foods = [:]; return
        }
        foods = Dictionary(uniqueKeysWithValues: rows.map { ($0.canonicalID, $0) })
    }
    func food(for canonicalID: String) -> ReferenceFood? { foods[canonicalID] }
}
