import Foundation
import SwiftData

protocol BarcodeProvider { func lookup(_ barcode: String) async throws -> BarcodeProductCache? }

struct OpenFoodFactsService: BarcodeProvider {
    var session: URLSession = .shared
    func lookup(_ barcode: String) async throws -> BarcodeProductCache? {
        guard barcode.range(of: #"^\d{6,14}$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("NutritionTracker/1.0 (personal iOS app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(OFFResponse.self, from: data)
        guard decoded.status == 1, let product = decoded.product else { return nil }
        let name = product.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let n = product.nutriments
        let per100g = Nutrition(calories: n?.energyKcal100g ?? 0, protein: n?.proteins100g ?? 0,
                                  carbs: n?.carbohydrates100g ?? 0, fat: n?.fat100g ?? 0,
                                  fibre: n?.fiber100g ?? 0, sugar: n?.sugars100g ?? 0,
                                  sodium: (n?.sodium100g ?? 0) * 1000)
        let serving = Self.parseServing(product.servingSize)
        let nutrition = per100g * (serving.size / 100)
        guard nutrition.isValid else { return nil }
        return BarcodeProductCache(barcode: barcode, name: name, brand: product.brands,
                                   servingSize: serving.size, unit: serving.unit, nutrition: nutrition)
    }
    static func parseServing(_ raw: String?) -> (size: Double, unit: ServingUnit) {
        guard let raw,
              let range = raw.range(of: #"\d+(?:[.,]\d+)?\s*(?:g|ml)\b"#, options: [.regularExpression, .caseInsensitive]) else {
            return (100, .gram)
        }
        let match = String(raw[range]).lowercased().replacingOccurrences(of: ",", with: ".")
        let number = Double(match.prefix { $0.isNumber || $0 == "." }) ?? 100
        return (number > 0 ? number : 100, match.hasSuffix("ml") ? .millilitre : .gram)
    }
}

struct OFFResponse: Decodable {
    let status: Int?
    let product: OFFProduct?
}
struct OFFProduct: Decodable {
    let productName: String?
    let brands: String?
    let servingSize: String?
    let nutriments: OFFNutriments?
    enum CodingKeys: String, CodingKey { case productName = "product_name", brands, servingSize = "serving_size", nutriments }
}
struct OFFNutriments: Decodable {
    let energyKcal100g, proteins100g, carbohydrates100g, fat100g, fiber100g, sugars100g, sodium100g: Double?
    enum CodingKeys: String, CodingKey {
        case energyKcal100g = "energy-kcal_100g", proteins100g = "proteins_100g"
        case carbohydrates100g = "carbohydrates_100g", fat100g = "fat_100g"
        case fiber100g = "fiber_100g", sugars100g = "sugars_100g", sodium100g = "sodium_100g"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) -> Double? {
            if let d = try? c.decode(Double.self, forKey: key) { return d }
            if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
            return nil
        }
        energyKcal100g = value(.energyKcal100g); proteins100g = value(.proteins100g)
        carbohydrates100g = value(.carbohydrates100g); fat100g = value(.fat100g)
        fiber100g = value(.fiber100g); sugars100g = value(.sugars100g); sodium100g = value(.sodium100g)
    }
}
