import Foundation
import CoreML
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// Model A: recognises and locates the foods/ingredients in one image
/// (spec section 18).
protocol IngredientRecognitionService: Sendable {
    /// Whether a usable model is actually present on disk.
    var isAvailable: Bool { get }
    var modelIdentifier: String { get }

    func recognise(image: PreparedImage) async throws -> IngredientRecognitionOutput
}

/// Model B: estimates per-ingredient mass and, as a consistency signal, the
/// whole-plate nutrition (spec section 18).
protocol PortionNutritionService: Sendable {
    var isAvailable: Bool { get }
    var modelIdentifier: String { get }

    func estimate(image: PreparedImage,
                  detections: [DetectedIngredient]) async throws -> PortionNutritionOutput
}

/// An image already decoded, resized and normalised once, so neither model has
/// to decode it again (spec section 40).
struct PreparedImage: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pixelSize: CGSize
    /// JPEG bytes, kept for retaining the image after saving.
    let jpegData: Data

    static let targetEdge: CGFloat = 640
}

// MARK: - Core ML model location

/// Where the compiled models are expected to live, and whether they are there.
///
/// The app must compile and run with neither model present (spec section 37).
enum ModelCatalogue {

    /// Model A. Expected in the app bundle as `IngredientSegmenter.mlmodelc`
    /// (Xcode compiles a bundled `IngredientSegmenter.mlpackage` to this).
    static let modelAName = "IngredientSegmenter"

    /// Model B. Expected as `NutritionEstimator.mlmodelc`.
    static let modelBName = "NutritionEstimator"

    static func compiledModelURL(named name: String,
                                 bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: "mlmodelc")
    }

    static func isPresent(_ name: String, bundle: Bundle = .main) -> Bool {
        compiledModelURL(named: name, bundle: bundle) != nil
    }

    static func loadModel(named name: String,
                          bundle: Bundle = .main) throws -> MLModel {
        guard let url = compiledModelURL(named: name, bundle: bundle) else {
            throw AIServiceError.modelUnavailable(name: name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw AIServiceError.inferenceFailed(detail: error.localizedDescription)
        }
    }
}

// MARK: - Model A: Core ML implementation

/// Core ML-backed Model A.
///
/// Reads the label ontology from the bundle and maps raw class names to
/// canonical identifiers (spec section 22). Handles two output shapes:
///
///  1. **Segmentation summary** (what `ml/ingredient_segmentation/export.py`
///     produces): `class_confidence` and `class_area` multi-arrays, one value per
///     class, with the class labels stored in the model's metadata. The full
///     mask is reduced on-device to these two vectors inside the model, so the
///     app never decodes a pixel map.
///  2. **Object detector** (e.g. a swapped-in YOLO-style model exported with
///     NMS): read through Vision as labelled objects.
///
/// Keeping both paths means the segmentation model can be replaced without
/// touching the rest of the pipeline (spec section 19).
final class CoreMLIngredientRecognitionService: IngredientRecognitionService, @unchecked Sendable {

    /// Output names written by the export script. Kept in one place so the
    /// Python and Swift sides cannot drift apart silently.
    enum SummaryOutput {
        static let confidence = "class_confidence"
        static let area = "class_area"
        static let labelsMetadataKey = "labels"
    }

    /// Classes covering less of the image than this are treated as noise.
    static let minimumAreaFraction = 0.01

    let modelIdentifier: String
    private let ontology: FoodOntology
    private let bundle: Bundle
    /// Loaded lazily and cached: loading a Core ML model is expensive and must
    /// not happen on the main thread during a tab switch.
    private let modelBox = ModelBox()

    init(ontology: FoodOntology = .shared, bundle: Bundle = .main) {
        self.ontology = ontology
        self.bundle = bundle
        self.modelIdentifier = ModelCatalogue.modelAName
    }

    var isAvailable: Bool {
        ModelCatalogue.isPresent(ModelCatalogue.modelAName, bundle: bundle)
    }

    func recognise(image: PreparedImage) async throws -> IngredientRecognitionOutput {
        guard isAvailable else {
            throw AIServiceError.modelUnavailable(name: ModelCatalogue.modelAName)
        }

        let model = try await modelBox.model {
            try ModelCatalogue.loadModel(named: ModelCatalogue.modelAName, bundle: self.bundle)
        }

        let outputs = model.modelDescription.outputDescriptionsByName
        if outputs[SummaryOutput.confidence] != nil, outputs[SummaryOutput.area] != nil {
            let detections = try recogniseWithSummary(model: model, image: image)
            return IngredientRecognitionOutput(detections: detections,
                                               modelIdentifier: modelIdentifier)
        }

        let visionModel: VNCoreMLModel
        do {
            visionModel = try VNCoreMLModel(for: model)
        } catch {
            throw AIServiceError.unsupportedModelOutput(detail: error.localizedDescription)
        }

        let observations = try await performRequest(model: visionModel, image: image)
        let detections = map(observations: observations, imageSize: image.pixelSize)

        return IngredientRecognitionOutput(detections: detections,
                                           modelIdentifier: modelIdentifier)
    }

    // MARK: Segmentation-summary path

    private func recogniseWithSummary(model: MLModel,
                                      image: PreparedImage) throws -> [DetectedIngredient] {
        guard let labels = Self.labels(from: model), !labels.isEmpty else {
            throw AIServiceError.unsupportedModelOutput(
                detail: "model metadata has no \"\(SummaryOutput.labelsMetadataKey)\" list")
        }
        let outputs = try VisionFeatureRunner.run(model: model, image: image)

        guard let confidence = outputs[SummaryOutput.confidence]?.multiArrayValue,
              let area = outputs[SummaryOutput.area]?.multiArrayValue else {
            throw AIServiceError.unsupportedModelOutput(detail: "missing summary outputs")
        }

        return Self.detections(labels: labels,
                               confidence: (0..<confidence.count).map { confidence[$0].doubleValue },
                               area: (0..<area.count).map { area[$0].doubleValue },
                               ontology: ontology)
    }

    /// Pure decoding step, separated so it can be unit tested without a model.
    static func detections(labels: [String],
                           confidence: [Double],
                           area: [Double],
                           ontology: FoodOntology) -> [DetectedIngredient] {
        let count = min(labels.count, confidence.count, area.count)
        var results: [DetectedIngredient] = []
        for index in 0..<count {
            let label = labels[index]
            // Index 0 is background by convention in the export script.
            guard label != "background" else { continue }
            let areaFraction = area[index]
            let score = confidence[index]
            guard areaFraction.isFinite, score.isFinite,
                  areaFraction >= minimumAreaFraction, score > 0.10 else { continue }

            let mapped = ontology.resolve(rawLabel: label)
            results.append(DetectedIngredient(
                rawLabel: label,
                canonicalID: mapped?.canonicalID,
                displayName: mapped?.displayName ?? label.humanisedLabel,
                confidence: min(max(score, 0), 1),
                boundingBox: nil,
                areaFraction: min(max(areaFraction, 0), 1)))
        }
        return results.sorted { $0.confidence > $1.confidence }
    }

    static func labels(from model: MLModel) -> [String]? {
        let metadata = model.modelDescription.metadata
        guard let userDefined = metadata[.creatorDefinedKey] as? [String: String],
              let json = userDefined[SummaryOutput.labelsMetadataKey],
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    // MARK: Vision detector path

    /// `perform` is synchronous, so results are read straight off the request
    /// afterwards. That avoids a completion-handler continuation, which could be
    /// resumed twice if Vision both reported an error and threw.
    private func performRequest(model: VNCoreMLModel,
                                image: PreparedImage) async throws -> [VNObservation] {
        let request = VNCoreMLRequest(model: model)
        // The model was trained on square crops; scaleFill keeps the whole
        // plate in frame rather than cropping the edges off a wide photo.
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: image.pixelBuffer,
                                            orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AIServiceError.inferenceFailed(detail: error.localizedDescription)
        }
        return request.results ?? []
    }

    /// Accepts whichever observation type the exported model produces. Anything
    /// unrecognised yields no detections rather than a crash (spec section 34).
    private func map(observations: [VNObservation], imageSize: CGSize) -> [DetectedIngredient] {
        var detections: [DetectedIngredient] = []

        for observation in observations {
            switch observation {
            case let recognised as VNRecognizedObjectObservation:
                guard let top = recognised.labels.first else { continue }
                let box = recognised.boundingBox
                detections.append(makeDetection(label: top.identifier,
                                                confidence: Double(top.confidence),
                                                boundingBox: NormalisedRect(box),
                                                areaFraction: Double(box.width * box.height)))

            case let classification as VNClassificationObservation:
                detections.append(makeDetection(label: classification.identifier,
                                                confidence: Double(classification.confidence),
                                                boundingBox: nil,
                                                areaFraction: nil))

            default:
                // Raw feature-value outputs are handled by the summary path
                // above, never here. Anything else is ignored rather than
                // guessed at (spec section 34).
                continue
            }
        }

        // Keep the strongest detection per canonical food so one ingredient does
        // not appear three times from overlapping boxes.
        var best: [String: DetectedIngredient] = [:]
        for detection in detections {
            let key = detection.canonicalID ?? detection.rawLabel.lowercased()
            if let existing = best[key], existing.confidence >= detection.confidence {
                continue
            }
            best[key] = detection
        }

        return best.values
            .filter { $0.confidence > 0.10 }
            .sorted { $0.confidence > $1.confidence }
    }

    private func makeDetection(label: String, confidence: Double,
                               boundingBox: NormalisedRect?,
                               areaFraction: Double?) -> DetectedIngredient {
        let mapped = ontology.resolve(rawLabel: label)
        return DetectedIngredient(rawLabel: label,
                                  canonicalID: mapped?.canonicalID,
                                  displayName: mapped?.displayName ?? label.humanisedLabel,
                                  confidence: confidence,
                                  boundingBox: boundingBox,
                                  areaFraction: areaFraction)
    }
}

// MARK: - Model B: Core ML implementation

final class CoreMLPortionNutritionService: PortionNutritionService, @unchecked Sendable {

    let modelIdentifier: String
    private let bundle: Bundle
    private let modelBox = ModelBox()

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        self.modelIdentifier = ModelCatalogue.modelBName
    }

    var isAvailable: Bool {
        ModelCatalogue.isPresent(ModelCatalogue.modelBName, bundle: bundle)
    }

    func estimate(image: PreparedImage,
                  detections: [DetectedIngredient]) async throws -> PortionNutritionOutput {
        guard isAvailable else {
            throw AIServiceError.modelUnavailable(name: ModelCatalogue.modelBName)
        }

        let model = try await modelBox.model {
            try ModelCatalogue.loadModel(named: ModelCatalogue.modelBName, bundle: self.bundle)
        }

        let outputs = try VisionFeatureRunner.run(model: model, image: image)
        return decode(outputs: outputs, detections: detections)
    }

    /// Decodes the multi-task regression head. Missing outputs are tolerated:
    /// a model exported without the per-ingredient mass head still yields a
    /// whole-plate prediction.
    private func decode(outputs: [String: MLFeatureValue],
                        detections: [DetectedIngredient]) -> PortionNutritionOutput {

        func scalar(_ name: String) -> Double? {
            guard let value = outputs[name] else { return nil }
            switch value.type {
            case .double, .int64:
                return value.doubleValue
            case .multiArray:
                guard let array = value.multiArrayValue, array.count > 0 else { return nil }
                return array[0].doubleValue
            default:
                return nil
            }
        }

        let plate: Nutrition? = {
            let calories = scalar("calories")
            let protein = scalar("protein")
            let carbs = scalar("carbs")
            let fat = scalar("fat")
            guard calories != nil || protein != nil || carbs != nil || fat != nil else {
                return nil
            }
            return Nutrition(calories: calories ?? 0,
                             protein: protein ?? 0,
                             carbs: carbs ?? 0,
                             fat: fat ?? 0).sanitised
        }()

        let totalMass = scalar("mass")

        // Per-ingredient masses, if the head exists; otherwise the total mass is
        // split by detected area, which is a weak but honest heuristic.
        var portions: [PortionEstimate] = []
        if let massArray = outputs["ingredient_mass"]?.multiArrayValue,
           massArray.count >= detections.count {
            for (index, detection) in detections.enumerated() {
                portions.append(PortionEstimate(
                    detectionID: detection.id,
                    estimatedGrams: max(0, massArray[index].doubleValue),
                    confidence: detection.confidence))
            }
        } else {
            portions = Self.splitByArea(totalMass: totalMass ?? 0, detections: detections)
        }

        return PortionNutritionOutput(portions: portions,
                                      wholePlateNutrition: plate,
                                      modelIdentifier: modelIdentifier)
    }

    /// Distributes a total mass across detections by relative plate area.
    ///
    /// This is deliberately crude. A single handheld RGB photo carries real,
    /// unavoidable ambiguity about mass - Nutrition5k was captured on a fixed
    /// overhead rig with depth sensing, which a phone snapshot does not have -
    /// so this is a starting point the user is expected to correct
    /// (spec sections 18 and 44).
    static func splitByArea(totalMass: Double,
                            detections: [DetectedIngredient]) -> [PortionEstimate] {
        guard !detections.isEmpty else { return [] }
        let fallbackMass = totalMass > 0 ? totalMass : Double(detections.count) * 100
        let areas = detections.map { $0.areaFraction ?? (1.0 / Double(detections.count)) }
        let totalArea = areas.reduce(0, +)

        return zip(detections, areas).map { detection, area in
            let share = totalArea > 0 ? area / totalArea : 1.0 / Double(detections.count)
            return PortionEstimate(detectionID: detection.id,
                                   estimatedGrams: (fallbackMass * share).rounded(),
                                   confidence: detection.confidence)
        }
    }
}

// MARK: - Unavailable implementations

/// Stand-in used when no model file is bundled.
///
/// This is not a mock that fabricates plausible food: it reports unavailability
/// so the UI can tell the truth and fall back to manual entry
/// (spec sections 25 and 37).
struct UnavailableIngredientRecognitionService: IngredientRecognitionService {
    var isAvailable: Bool { false }
    var modelIdentifier: String { "\(ModelCatalogue.modelAName) (not installed)" }

    func recognise(image: PreparedImage) async throws -> IngredientRecognitionOutput {
        throw AIServiceError.modelUnavailable(name: ModelCatalogue.modelAName)
    }
}

struct UnavailablePortionNutritionService: PortionNutritionService {
    var isAvailable: Bool { false }
    var modelIdentifier: String { "\(ModelCatalogue.modelBName) (not installed)" }

    func estimate(image: PreparedImage,
                  detections: [DetectedIngredient]) async throws -> PortionNutritionOutput {
        throw AIServiceError.modelUnavailable(name: ModelCatalogue.modelBName)
    }
}

// MARK: - Helpers

/// Runs a Core ML model through Vision and returns its raw named outputs.
///
/// Going through Vision rather than `MLModel.prediction` matters: the exported
/// models take a fixed square input, while prepared photos keep their aspect
/// ratio. Vision rescales to the model's input constraint; a direct prediction
/// call would fail with a size mismatch.
enum VisionFeatureRunner {
    static func run(model: MLModel, image: PreparedImage) throws -> [String: MLFeatureValue] {
        let visionModel: VNCoreMLModel
        do {
            visionModel = try VNCoreMLModel(for: model)
        } catch {
            throw AIServiceError.unsupportedModelOutput(detail: error.localizedDescription)
        }

        let request = VNCoreMLRequest(model: visionModel)
        // Whole plate in frame; matches the square resize used in training.
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: image.pixelBuffer,
                                            orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AIServiceError.inferenceFailed(detail: error.localizedDescription)
        }

        var outputs: [String: MLFeatureValue] = [:]
        for case let observation as VNCoreMLFeatureValueObservation in request.results ?? [] {
            outputs[observation.featureName] = observation.featureValue
        }
        guard !outputs.isEmpty else {
            throw AIServiceError.unsupportedModelOutput(detail: "model produced no feature outputs")
        }
        return outputs
    }
}

/// Serialises lazy model loading so two concurrent analyses cannot each load a
/// separate copy of the same model.
private actor ModelBox {
    private var loaded: MLModel?

    func model(_ make: @Sendable () throws -> MLModel) throws -> MLModel {
        if let loaded { return loaded }
        let model = try make()
        loaded = model
        return model
    }
}

extension String {
    /// "fried_egg" / "friedEgg" -> "Fried Egg"
    var humanisedLabel: String {
        let spaced = replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return spaced.split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
