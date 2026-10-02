import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates the two-specialist-model photo pipeline (spec section 18).
///
///   photo
///     -> prepare image once
///     -> Model A (recognition / segmentation) -> classes + confidence
///     -> Model B (portion mass, plus a whole-plate nutrition signal)
///     -> canonical nutrition lookup (MyFCD / generic / local)
///     -> per-ingredient nutrition, summed in Swift
///     -> Add Meal review (mandatory)
///
/// Nothing here writes to the database. The result becomes a draft the user must
/// review and confirm, which is the only way an AI-derived entry can be saved.
@MainActor
@Observable
final class PhotoAnalysisPipeline {

    private(set) var stage: AnalysisStage = .preparingImage
    private(set) var isRunning = false

    private let recognition: IngredientRecognitionService
    private let portion: PortionNutritionService
    private let remote: RemoteVisionService
    private let repository: NutritionRepository

    init(recognition: IngredientRecognitionService,
         portion: PortionNutritionService,
         remote: RemoteVisionService,
         repository: NutritionRepository) {
        self.recognition = recognition
        self.portion = portion
        self.remote = remote
        self.repository = repository
    }

    /// Convenience factory wiring the real services, each degrading to an
    /// "unavailable" implementation when its model file is absent
    /// (spec section 37).
    @MainActor
    static func make(context: ModelContext, settings: AppSettings) -> PhotoAnalysisPipeline {
        let modelA: IngredientRecognitionService =
            ModelCatalogue.isPresent(ModelCatalogue.modelAName)
            ? CoreMLIngredientRecognitionService()
            : UnavailableIngredientRecognitionService()

        let modelB: PortionNutritionService =
            ModelCatalogue.isPresent(ModelCatalogue.modelBName)
            ? CoreMLPortionNutritionService()
            : UnavailablePortionNutritionService()

        let remote: RemoteVisionService =
            settings.remoteVisionFallbackEnabled
                && APIKeyResolver.hasKey(for: .remoteVisionAPIKey)
            ? AnthropicRemoteVisionService()
            : DisabledRemoteVisionService()

        return PhotoAnalysisPipeline(recognition: modelA,
                                     portion: modelB,
                                     remote: remote,
                                     repository: NutritionRepository(context: context))
    }

    var modelAStatus: ModelStatus {
        ModelStatus(name: ModelCatalogue.modelAName,
                    identifier: recognition.modelIdentifier,
                    isAvailable: recognition.isAvailable)
    }

    var modelBStatus: ModelStatus {
        ModelStatus(name: ModelCatalogue.modelBName,
                    identifier: portion.modelIdentifier,
                    isAvailable: portion.isAvailable)
    }

    var hasAnyAnalysisCapability: Bool {
        recognition.isAvailable || remote.isConfigured
    }

    // MARK: Run

    #if canImport(UIKit)
    /// Analyses one image. Throws only when there is nothing usable at all; a
    /// partial result (foods found, masses guessed) is returned rather than
    /// failing, because the user can correct it.
    func analyse(image: UIImage, retainImage: Bool) async throws -> PhotoAnalysisResult {
        isRunning = true
        stage = .preparingImage
        defer { isRunning = false }

        // Image prep is CPU-bound; keep it off the main actor so the progress
        // UI keeps animating (spec section 40).
        let prepared = try await Task.detached(priority: .userInitiated) {
            try ImagePreparer.prepare(image: image)
        }.value

        try Task.checkCancellation()

        // --- Model A, with the optional remote fallback.
        stage = .identifyingFoods
        var usedRemote = false
        var recognitionOutput: IngredientRecognitionOutput

        do {
            recognitionOutput = try await recognition.recognise(image: prepared)
            if recognitionOutput.detections.isEmpty, remote.isConfigured {
                recognitionOutput = try await remote.identifyFoods(in: prepared)
                usedRemote = true
            }
        } catch {
            guard remote.isConfigured else {
                // No local model and no fallback: surface the real reason so the
                // UI can offer manual entry instead of pretending (section 25).
                throw error
            }
            recognitionOutput = try await remote.identifyFoods(in: prepared)
            usedRemote = true
        }

        try Task.checkCancellation()

        // --- Model B. A failure here is not fatal: without masses the pipeline
        //     still reports what was detected, with portions the user sets.
        stage = .estimatingPortions
        var portionOutput: PortionNutritionOutput
        do {
            portionOutput = try await portion.estimate(image: prepared,
                                                       detections: recognitionOutput.detections)
        } catch {
            portionOutput = PortionNutritionOutput(
                portions: CoreMLPortionNutritionService.splitByArea(
                    totalMass: 0, detections: recognitionOutput.detections),
                wholePlateNutrition: nil,
                modelIdentifier: portion.modelIdentifier)
        }

        try Task.checkCancellation()

        // --- Canonical nutrition join, then Swift arithmetic.
        stage = .calculatingNutrition
        let resolved = repository.resolve(detections: recognitionOutput.detections,
                                          portions: portionOutput.portions,
                                          wholePlateNutrition: portionOutput.wholePlateNutrition)

        stage = .preparingMeal
        var photoPath: String?
        if retainImage {
            // A failed photo write must not fail the analysis.
            photoPath = try? ImageStore.save(jpegData: prepared.jpegData)
        }

        stage = .finished

        return PhotoAnalysisResult(detections: recognitionOutput.detections,
                                   portions: portionOutput.portions,
                                   wholePlateNutrition: portionOutput.wholePlateNutrition,
                                   resolvedNutrition: resolved,
                                   photoPath: photoPath,
                                   modelAIdentifier: recognitionOutput.modelIdentifier,
                                   modelBIdentifier: portionOutput.modelIdentifier,
                                   usedRemoteFallback: usedRemote,
                                   producedAt: .now)
    }
    #endif
}

struct ModelStatus: Equatable, Sendable {
    let name: String
    let identifier: String
    let isAvailable: Bool

    var statusText: String { isAvailable ? "Installed" : "Not installed" }
}

// MARK: - Result -> draft

extension PhotoAnalysisResult {

    /// Converts a pipeline result into the editable draft the user reviews
    /// (spec sections 18, 28).
    ///
    /// A multi-ingredient result becomes a composite food; a single detection
    /// becomes a simple food, since wrapping one ingredient in a parent adds a
    /// layer with no benefit.
    func makeDraft(name suggestedName: String? = nil) -> FoodEntryDraft {
        var draft = makeBareDraft(name: suggestedName)
        draft.predictionJSON = try? JSONEncoder().encode(self)
        return draft
    }

    private func makeBareDraft(name suggestedName: String?) -> FoodEntryDraft {
        let ingredients = resolvedNutrition.map { resolved in
            IngredientDraft(
                name: resolved.displayName,
                quantity: resolved.grams > 0 ? resolved.grams.rounded() : 100,
                // Reference figures are per 100 g, so the serving size is 100 g
                // and the quantity carries the estimated mass.
                servingSize: 100,
                unit: .gram,
                nutritionPerServing: resolved.nutritionPer100g,
                confidence: resolved.confidence,
                canonicalID: resolved.canonicalID,
                provenance: resolved.provenance)
        }

        let fallbackName = suggestedName
            ?? Self.suggestName(from: resolvedNutrition.map(\.displayName))

        if ingredients.count == 1, let only = ingredients.first {
            return FoodEntryDraft(name: only.name,
                                  quantity: only.quantity,
                                  servingSize: only.servingSize,
                                  unit: only.unit,
                                  nutritionPerServing: only.nutritionPerServing,
                                  ingredients: [],
                                  source: .photoAI,
                                  photoPath: photoPath,
                                  canonicalID: only.canonicalID,
                                  confidence: only.confidence)
        }

        return FoodEntryDraft(name: fallbackName,
                              quantity: 1,
                              servingSize: 1,
                              unit: .serving,
                              nutritionPerServing: .zero,
                              ingredients: ingredients,
                              source: .photoAI,
                              photoPath: photoPath)
    }

    /// "Rice, Chicken and Cucumber" from the detected names. The user is
    /// expected to rename a composite food anyway (spec section 10).
    static func suggestName(from names: [String]) -> String {
        let unique = Array(NSOrderedSet(array: names).array as? [String] ?? names)
        switch unique.count {
        case 0: return "Meal"
        case 1: return unique[0]
        case 2: return "\(unique[0]) and \(unique[1])"
        default:
            let head = unique.prefix(2).joined(separator: ", ")
            return "\(head) and \(unique.count - 2) more"
        }
    }
}
