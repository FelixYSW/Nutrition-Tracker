import Foundation
import CoreGraphics

/// Progress stages surfaced during analysis (spec section 28).
enum AnalysisStage: String, Codable, Hashable, Sendable {
    case preparingImage
    case identifyingFoods
    case estimatingPortions
    case calculatingNutrition
    case preparingMeal
    case finished

    var displayName: String {
        switch self {
        case .preparingImage: "Image prepared"
        case .identifyingFoods: "Foods identified"
        case .estimatingPortions: "Estimating portions"
        case .calculatingNutrition: "Calculating nutrition"
        case .preparingMeal: "Preparing meal"
        case .finished: "Done"
        }
    }

    var order: Int {
        switch self {
        case .preparingImage: 0
        case .identifyingFoods: 1
        case .estimatingPortions: 2
        case .calculatingNutrition: 3
        case .preparingMeal: 4
        case .finished: 5
        }
    }

    static let orderedCases: [AnalysisStage] = [
        .preparingImage, .identifyingFoods, .estimatingPortions,
        .calculatingNutrition, .preparingMeal
    ]

    var fractionComplete: Double {
        Double(order) / Double(AnalysisStage.finished.order)
    }
}

// MARK: - Model A output

/// One food/ingredient located by Model A.
struct DetectedIngredient: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    /// Label as the model emitted it, before ontology mapping.
    var rawLabel: String
    /// Canonical ontology identifier, once mapped (spec section 22).
    var canonicalID: String?
    /// Human-readable name for the UI.
    var displayName: String
    var confidence: Double
    /// Normalised bounding box in image space, when the model provides one.
    var boundingBox: NormalisedRect?
    /// Fraction of the plate area this detection covers. Model B uses it as a
    /// weak portion cue when no better signal exists.
    var areaFraction: Double?

    var isLowConfidence: Bool { confidence < NutritionConstants.lowConfidenceThreshold }
}

/// Codable stand-in for `CGRect` with values in 0...1.
struct NormalisedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y,
                  width: rect.size.width, height: rect.size.height)
    }
}

struct IngredientRecognitionOutput: Codable, Equatable, Sendable {
    var detections: [DetectedIngredient]
    /// Identifier of the model that produced this, for the correction dataset.
    var modelIdentifier: String
}

// MARK: - Model B output

/// Per-ingredient mass estimate from Model B.
struct PortionEstimate: Codable, Equatable, Sendable {
    /// Matches `DetectedIngredient.id`.
    var detectionID: UUID
    var estimatedGrams: Double
    var confidence: Double
}

struct PortionNutritionOutput: Codable, Equatable, Sendable {
    var portions: [PortionEstimate]
    /// Whole-plate nutrition prediction. Used only as a fallback or a
    /// consistency check, never as the primary source when a canonical match
    /// exists (spec section 23).
    var wholePlateNutrition: Nutrition?
    var modelIdentifier: String
}

// MARK: - Pipeline result

/// Everything the pipeline produced, retained verbatim for the correction
/// dataset before the user edits anything (spec section 24).
struct PhotoAnalysisResult: Codable, Equatable, Sendable {
    var detections: [DetectedIngredient]
    var portions: [PortionEstimate]
    var wholePlateNutrition: Nutrition?
    var resolvedNutrition: [ResolvedIngredientNutrition]
    var photoPath: String?
    var modelAIdentifier: String
    var modelBIdentifier: String
    /// False when Model B was unavailable, so the amounts are defaults rather
    /// than estimates and the UI says so.
    var portionsEstimated: Bool
    var producedAt: Date

    /// True when nothing usable was found, so the UI offers manual entry
    /// instead of an empty draft (spec section 25).
    var isEmpty: Bool { detections.isEmpty }
}

/// A detection joined to real nutrition figures by the data layer.
struct ResolvedIngredientNutrition: Codable, Equatable, Sendable {
    var detectionID: UUID
    var displayName: String
    var canonicalID: String?
    var grams: Double
    /// Nutrition per 100 g, as the reference tables store it.
    var nutritionPer100g: Nutrition
    var provenance: NutritionProvenance
    var confidence: Double

    /// Nutrition for the estimated mass.
    var total: Nutrition { nutritionPer100g * (grams / 100) }
}

// MARK: - Errors

enum AIServiceError: LocalizedError, Equatable {
    case modelUnavailable(name: String)
    case invalidImage
    case unsupportedModelOutput(detail: String)
    case inferenceFailed(detail: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let name):
            "The on-device model \"\(name)\" is not available in this build."
        case .invalidImage:
            "That image could not be read."
        case .unsupportedModelOutput(let detail):
            "The model returned output this app cannot read (\(detail))."
        case .inferenceFailed(let detail):
            "Analysis failed: \(detail)"
        case .cancelled:
            "Analysis was cancelled."
        }
    }

    var isModelUnavailable: Bool {
        if case .modelUnavailable = self { return true }
        return false
    }
}
