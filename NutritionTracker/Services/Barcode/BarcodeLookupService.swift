import Foundation
import SwiftData

/// Resolves a barcode through the cache first, then the remote provider
/// (spec section 27).
///
/// Barcode results bypass image recognition entirely - there is no reason to run
/// a vision model on a product with a declared label.
@MainActor
final class BarcodeLookupService {

    private let context: ModelContext
    private let provider: BarcodeProductProviding

    /// How long a cached remote product stays fresh. User-entered products never
    /// expire, because the user is the authority on them.
    static let cacheLifetime: TimeInterval = 60 * 60 * 24 * 90

    init(context: ModelContext,
         provider: BarcodeProductProviding = OpenFoodFactsService()) {
        self.context = context
        self.provider = provider
    }

    enum Outcome: Equatable {
        case found(BarcodeProduct, fromCache: Bool)
        case notFound(barcode: String)
    }

    /// Cache hit avoids the network entirely (spec sections 23, 40).
    func lookup(barcode: String) async throws -> Outcome {
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BarcodeLookupError.invalidBarcode }

        if let cached = context.fetchCachedProduct(barcode: trimmed), isFresh(cached) {
            return .found(product(from: cached), fromCache: true)
        }

        do {
            guard let product = try await provider.fetchProduct(barcode: trimmed) else {
                return .notFound(barcode: trimmed)
            }
            cache(product: product, isUserEntered: false)
            return .found(product, fromCache: false)
        } catch BarcodeLookupError.notFound {
            return .notFound(barcode: trimmed)
        } catch {
            // Offline or timed out: a stale cache entry is far better than
            // nothing, so fall back to it and let the caller carry on.
            if let cached = context.fetchCachedProduct(barcode: trimmed) {
                return .found(product(from: cached), fromCache: true)
            }
            throw error
        }
    }

    private func isFresh(_ cached: BarcodeProductCache) -> Bool {
        if cached.isUserEntered { return true }
        return Date.now.timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime
    }

    private func product(from cached: BarcodeProductCache) -> BarcodeProduct {
        BarcodeProduct(barcode: cached.barcode,
                       name: cached.name,
                       brand: cached.brand,
                       servingSize: cached.servingSize,
                       unit: cached.unit,
                       nutritionPerServing: cached.nutritionPerServing)
    }

    /// Upserts into the local cache. A manually entered product is marked as
    /// such so it outranks the generic database later (spec section 23 tier 1).
    func cache(product: BarcodeProduct, isUserEntered: Bool) {
        if let existing = context.fetchCachedProduct(barcode: product.barcode) {
            // Never let a remote refresh clobber what the user typed in.
            if existing.isUserEntered && !isUserEntered { return }
            existing.name = product.name
            existing.brand = product.brand
            existing.servingSize = product.servingSize
            existing.unit = product.unit
            existing.nutritionPerServing = product.nutritionPerServing.sanitised
            existing.isUserEntered = isUserEntered || existing.isUserEntered
            existing.fetchedAt = .now
        } else {
            context.insert(BarcodeProductCache(
                barcode: product.barcode,
                name: product.name,
                brand: product.brand,
                servingSize: product.servingSize,
                unit: product.unit,
                nutritionPerServing: product.nutritionPerServing.sanitised,
                isUserEntered: isUserEntered))
        }
        try? context.save()
    }
}

extension BarcodeProduct {
    /// Barcode products go through the same mandatory review draft as every
    /// other entry path.
    func makeDraft() -> FoodEntryDraft {
        FoodEntryDraft(name: [brand, name].compactMap { $0 }.joined(separator: " "),
                       quantity: servingSize,
                       servingSize: servingSize,
                       unit: unit,
                       nutritionPerServing: nutritionPerServing,
                       ingredients: [],
                       source: .barcode,
                       barcode: barcode)
    }
}
