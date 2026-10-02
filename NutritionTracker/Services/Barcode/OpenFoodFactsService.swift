import Foundation

/// A packaged product resolved from a barcode.
struct BarcodeProduct: Equatable, Sendable {
    var barcode: String
    var name: String
    var brand: String?
    /// Serving size the nutrition figures refer to.
    var servingSize: Double
    var unit: ServingUnit
    var nutritionPerServing: Nutrition
}

/// Behind a protocol so a second provider can be added without touching the
/// scan flow (spec section 27).
protocol BarcodeProductProviding: Sendable {
    func fetchProduct(barcode: String) async throws -> BarcodeProduct?
}

enum BarcodeLookupError: LocalizedError, Equatable {
    case notFound(barcode: String)
    case network(detail: String)
    case malformedResponse
    case invalidBarcode

    var errorDescription: String? {
        switch self {
        case .notFound:
            "Product Not Found"
        case .network(let detail):
            "Could not reach the product database: \(detail)"
        case .malformedResponse:
            "The product database returned a response this app could not read."
        case .invalidBarcode:
            "That barcode does not look valid."
        }
    }
}

/// Open Food Facts client.
///
/// Every field is optional in practice, so each one is decoded defensively: a
/// product with no protein figure yields zero protein rather than a crash
/// (spec sections 27, 34).
struct OpenFoodFactsService: BarcodeProductProviding {

    private let session: URLSession

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()) {
        self.session = session
    }

    func fetchProduct(barcode: String) async throws -> BarcodeProduct? {
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
            throw BarcodeLookupError.invalidBarcode
        }

        // HTTPS only (spec section 39). v2 endpoint, requesting just the fields
        // actually used rather than the whole product record.
        var components = URLComponents(
            string: "https://world.openfoodfacts.org/api/v2/product/\(trimmed).json")!
        components.queryItems = [
            URLQueryItem(name: "fields",
                         value: "product_name,product_name_en,brands,serving_size,nutriments")
        ]
        guard let url = components.url else { throw BarcodeLookupError.invalidBarcode }

        var request = URLRequest(url: url)
        // Open Food Facts asks clients to identify themselves.
        request.setValue("NutritionTracker/2.0 (personal use)",
                         forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw BarcodeLookupError.network(detail: "the request timed out")
            }
            throw BarcodeLookupError.network(detail: error.localizedDescription)
        } catch {
            throw BarcodeLookupError.network(detail: error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw BarcodeLookupError.notFound(barcode: trimmed) }
            guard (200..<300).contains(http.statusCode) else {
                throw BarcodeLookupError.network(detail: "HTTP \(http.statusCode)")
            }
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw BarcodeLookupError.malformedResponse
        }

        guard envelope.status == 1, let product = envelope.product else {
            throw BarcodeLookupError.notFound(barcode: trimmed)
        }

        return Self.makeProduct(barcode: trimmed, product: product)
    }

    /// Maps an Open Food Facts product onto the app's model.
    ///
    /// Open Food Facts reports nutriments per 100 g, so the product is stored
    /// with a 100 g serving size and the figures used verbatim. `serving_size`
    /// is free text ("30 g", "1 biscuit (12.5g)") and is only parsed for display.
    static func makeProduct(barcode: String, product: Product) -> BarcodeProduct? {
        let name = [product.product_name, product.product_name_en]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        // A product with no name at all is not useful; treat it as not found so
        // the user gets the manual-entry path.
        guard let name, !name.isEmpty else { return nil }

        let nutriments = product.nutriments
        let nutrition = Nutrition(
            calories: nutriments?.energyKcalPer100g ?? 0,
            protein: nutriments?.proteins_100g ?? 0,
            carbs: nutriments?.carbohydrates_100g ?? 0,
            fat: nutriments?.fat_100g ?? 0,
            fibre: nutriments?.fiber_100g ?? 0,
            sugar: nutriments?.sugars_100g ?? 0,
            // Open Food Facts reports sodium in grams; the app stores milligrams.
            sodium: (nutriments?.sodiumGramsPer100g ?? 0) * 1000
        ).sanitised

        let brand = product.brands?
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return BarcodeProduct(barcode: barcode,
                              name: name,
                              brand: (brand?.isEmpty ?? true) ? nil : brand,
                              servingSize: 100,
                              unit: .gram,
                              nutritionPerServing: nutrition)
    }

    // MARK: Wire types

    struct Envelope: Decodable {
        /// 1 when found, 0 when not. Occasionally arrives as a string.
        let status: Int
        let product: Product?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let intStatus = try? container.decode(Int.self, forKey: .status) {
                status = intStatus
            } else if let stringStatus = try? container.decode(String.self, forKey: .status) {
                status = Int(stringStatus) ?? 0
            } else {
                status = 0
            }
            product = try? container.decodeIfPresent(Product.self, forKey: .product)
        }

        enum CodingKeys: String, CodingKey { case status, product }
    }

    struct Product: Decodable {
        let product_name: String?
        let product_name_en: String?
        let brands: String?
        let serving_size: String?
        let nutriments: Nutriments?
    }

    /// Open Food Facts emits numbers as either JSON numbers or strings,
    /// inconsistently, so every field goes through a lenient decoder.
    struct Nutriments: Decodable {
        let proteins_100g: Double?
        let carbohydrates_100g: Double?
        let fat_100g: Double?
        let fiber_100g: Double?
        let sugars_100g: Double?
        private let sodium_100g: Double?
        private let salt_100g: Double?
        private let energy_kcal_100g: Double?
        private let energy_100g: Double?

        /// Prefers the explicit kcal field, falling back to the kJ figure.
        var energyKcalPer100g: Double? {
            if let energy_kcal_100g { return energy_kcal_100g }
            if let energy_100g { return energy_100g / 4.184 }
            return nil
        }

        /// Sodium where given, otherwise derived from salt (salt = sodium x 2.5).
        var sodiumGramsPer100g: Double? {
            if let sodium_100g { return sodium_100g }
            if let salt_100g { return salt_100g / 2.5 }
            return nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ key: CodingKeys) -> Double? {
                if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                    return value.isFinite ? value : nil
                }
                if let string = try? container.decodeIfPresent(String.self, forKey: key) {
                    return Double(string.replacingOccurrences(of: ",", with: "."))
                }
                return nil
            }
            proteins_100g = number(.proteins_100g)
            carbohydrates_100g = number(.carbohydrates_100g)
            fat_100g = number(.fat_100g)
            fiber_100g = number(.fiber_100g)
            sugars_100g = number(.sugars_100g)
            sodium_100g = number(.sodium_100g)
            salt_100g = number(.salt_100g)
            energy_kcal_100g = number(.energy_kcal_100g)
            energy_100g = number(.energy_100g)
        }

        enum CodingKeys: String, CodingKey {
            case proteins_100g, carbohydrates_100g, fat_100g, fiber_100g,
                 sugars_100g, sodium_100g, salt_100g, energy_100g
            case energy_kcal_100g = "energy-kcal_100g"
        }
    }
}
