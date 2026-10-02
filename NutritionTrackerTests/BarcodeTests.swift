import XCTest
import SwiftData
@testable import NutritionTracker

final class OpenFoodFactsDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> OpenFoodFactsService.Envelope {
        try JSONDecoder().decode(OpenFoodFactsService.Envelope.self, from: Data(json.utf8))
    }

    func testFullProductDecodes() throws {
        let envelope = try decode("""
        {"status": 1, "product": {
          "product_name": "Milo Activ-Go", "brands": "Nestle, Milo",
          "serving_size": "30 g",
          "nutriments": {"energy-kcal_100g": 411, "proteins_100g": 8.4,
                         "carbohydrates_100g": 72.3, "fat_100g": 9.5,
                         "fiber_100g": 5.4, "sugars_100g": 41.6, "sodium_100g": 0.24}}}
        """)
        let product = try XCTUnwrap(OpenFoodFactsService.makeProduct(
            barcode: "9556001", product: try XCTUnwrap(envelope.product)))
        XCTAssertEqual(product.name, "Milo Activ-Go")
        XCTAssertEqual(product.brand, "Nestle", "first brand only")
        XCTAssertEqual(product.servingSize, 100)
        XCTAssertEqual(product.unit, .gram)
        XCTAssertEqual(product.nutritionPerServing.calories, 411)
        XCTAssertEqual(product.nutritionPerServing.fibre, 5.4)
        XCTAssertEqual(product.nutritionPerServing.sodium, 240, accuracy: 0.001, "g -> mg")
    }

    func testMissingFieldsDefaultToZeroWithoutCrashing() throws {
        let envelope = try decode("""
        {"status": 1, "product": {"product_name": "Mystery Snack", "nutriments": {}}}
        """)
        let product = try XCTUnwrap(OpenFoodFactsService.makeProduct(
            barcode: "1", product: try XCTUnwrap(envelope.product)))
        XCTAssertEqual(product.nutritionPerServing, .zero)
        XCTAssertNil(product.brand)
    }

    func testNoNutrimentsObjectAtAll() throws {
        let envelope = try decode(#"{"status": 1, "product": {"product_name": "Water"}}"#)
        let product = OpenFoodFactsService.makeProduct(barcode: "1",
                                                       product: try XCTUnwrap(envelope.product))
        XCTAssertEqual(product?.nutritionPerServing, .zero)
    }

    func testNumbersAsStringsAreAccepted() throws {
        let envelope = try decode("""
        {"status": "1", "product": {"product_name": "Biscuits",
          "nutriments": {"energy-kcal_100g": "480", "proteins_100g": "6,5", "fat_100g": "x"}}}
        """)
        XCTAssertEqual(envelope.status, 1)
        let product = try XCTUnwrap(OpenFoodFactsService.makeProduct(
            barcode: "1", product: try XCTUnwrap(envelope.product)))
        XCTAssertEqual(product.nutritionPerServing.calories, 480)
        XCTAssertEqual(product.nutritionPerServing.protein, 6.5, "comma decimal")
        XCTAssertEqual(product.nutritionPerServing.fat, 0, "garbage becomes zero")
    }

    func testKilojouleFallbackAndSaltToSodium() throws {
        let envelope = try decode("""
        {"status": 1, "product": {"product_name": "Crackers",
          "nutriments": {"energy_100g": 1841, "salt_100g": 1.25}}}
        """)
        let product = try XCTUnwrap(OpenFoodFactsService.makeProduct(
            barcode: "1", product: try XCTUnwrap(envelope.product)))
        XCTAssertEqual(product.nutritionPerServing.calories, 1841 / 4.184, accuracy: 0.01)
        XCTAssertEqual(product.nutritionPerServing.sodium, 500, accuracy: 0.01)
    }

    func testStatusZeroMeansNotFound() throws {
        let envelope = try decode(#"{"status": 0, "status_verbose": "product not found"}"#)
        XCTAssertEqual(envelope.status, 0)
        XCTAssertNil(envelope.product)
    }

    func testNamelessProductTreatedAsNotFound() throws {
        let envelope = try decode(#"{"status": 1, "product": {"product_name": "  "}}"#)
        XCTAssertNil(OpenFoodFactsService.makeProduct(barcode: "1",
                                                      product: try XCTUnwrap(envelope.product)))
    }

    func testFallsBackToEnglishName() throws {
        let envelope = try decode(#"{"status": 1, "product": {"product_name": "", "product_name_en": "Soy Milk"}}"#)
        XCTAssertEqual(OpenFoodFactsService.makeProduct(
            barcode: "1", product: try XCTUnwrap(envelope.product))?.name, "Soy Milk")
    }
}

/// Counts calls so tests can prove the cache prevents network requests.
final class MockBarcodeProvider: BarcodeProductProviding, @unchecked Sendable {
    var result: Result<BarcodeProduct?, Error>
    private(set) var callCount = 0

    init(result: Result<BarcodeProduct?, Error>) { self.result = result }

    func fetchProduct(barcode: String) async throws -> BarcodeProduct? {
        callCount += 1
        return try result.get()
    }
}

@MainActor
final class BarcodeCacheTests: XCTestCase {

    private let product = BarcodeProduct(barcode: "9555555000001", name: "Kaya Spread",
                                         brand: "Yeo's", servingSize: 100, unit: .gram,
                                         nutritionPerServing: Nutrition(calories: 300, carbs: 55))

    func testRemoteHitIsCachedAndSecondLookupSkipsNetwork() async throws {
        let context = TestSupport.makeContext()
        let provider = MockBarcodeProvider(result: .success(product))
        let service = BarcodeLookupService(context: context, provider: provider)

        let first = try await service.lookup(barcode: product.barcode)
        XCTAssertEqual(first, .found(product, fromCache: false))

        let second = try await service.lookup(barcode: product.barcode)
        XCTAssertEqual(second, .found(product, fromCache: true))
        XCTAssertEqual(provider.callCount, 1, "no redundant network request")
    }

    func testNotFoundIsReported() async throws {
        let context = TestSupport.makeContext()
        let provider = MockBarcodeProvider(result: .failure(BarcodeLookupError.notFound(barcode: "1")))
        let outcome = try await BarcodeLookupService(context: context, provider: provider)
            .lookup(barcode: "123")
        XCTAssertEqual(outcome, .notFound(barcode: "123"))
    }

    func testUserEnteredProductIsNeverOverwrittenByRemote() async throws {
        let context = TestSupport.makeContext()
        let service = BarcodeLookupService(context: context,
                                           provider: MockBarcodeProvider(result: .success(nil)))
        var mine = product
        mine.name = "My Kaya"
        service.cache(product: mine, isUserEntered: true)
        service.cache(product: product, isUserEntered: false)

        XCTAssertEqual(context.fetchCachedProduct(barcode: product.barcode)?.name, "My Kaya")
    }

    func testOfflineFallsBackToStaleCache() async throws {
        let context = TestSupport.makeContext()
        let cached = BarcodeProductCache(barcode: product.barcode, name: "Old Name",
                                         nutritionPerServing: Nutrition(calories: 1))
        cached.fetchedAt = Date.now.addingTimeInterval(-BarcodeLookupService.cacheLifetime * 2)
        context.insert(cached)
        try context.save()

        let provider = MockBarcodeProvider(result: .failure(BarcodeLookupError.network(detail: "offline")))
        let outcome = try await BarcodeLookupService(context: context, provider: provider)
            .lookup(barcode: product.barcode)

        XCTAssertEqual(provider.callCount, 1, "stale entry triggers a refresh attempt")
        guard case .found(let found, true) = outcome else {
            return XCTFail("expected stale cache fallback, got \(outcome)")
        }
        XCTAssertEqual(found.name, "Old Name")
    }

    func testOfflineWithNoCacheThrows() async {
        let context = TestSupport.makeContext()
        let provider = MockBarcodeProvider(result: .failure(BarcodeLookupError.network(detail: "offline")))
        do {
            _ = try await BarcodeLookupService(context: context, provider: provider).lookup(barcode: "42")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? BarcodeLookupError, .network(detail: "offline"))
        }
    }

    func testBarcodeProductBecomesReviewDraft() {
        let draft = product.makeDraft()
        XCTAssertEqual(draft.source, .barcode)
        XCTAssertEqual(draft.barcode, product.barcode)
        XCTAssertEqual(draft.name, "Yeo's Kaya Spread")
        XCTAssertEqual(draft.total.calories, 300, accuracy: 0.001)
    }
}
