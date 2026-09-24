import Foundation
import Vision
import CoreML
import ImageIO
import UniformTypeIdentifiers

struct Detection: Codable, Equatable {
    var name: String
    var canonicalID: String?
    var confidence: Double
    var region: CGRect?
}
struct PortionPrediction: Codable, Equatable {
    var canonicalID: String?
    var name: String
    var grams: Double
    var nutrition: Nutrition
}
struct AnalysisResult: Codable, Equatable {
    var detections: [Detection]
    var portions: [PortionPrediction]
}
enum AnalysisError: LocalizedError {
    case invalidImage, missingRecognitionModel, missingPortionModel, unsupportedOutput
    var errorDescription: String? {
        switch self {
        case .invalidImage: "The image could not be opened."
        case .missingRecognitionModel: "Local food recognition model unavailable. Add FoodRecognition.mlmodelc or enter food manually."
        case .missingPortionModel: "Local portion model unavailable. Portions need manual entry."
        case .unsupportedOutput: "The model output is not compatible with this app."
        }
    }
}
protocol IngredientRecognitionService { func recognize(_ image: CGImage) async throws -> [Detection] }
protocol PortionEstimationService { func estimate(_ image: CGImage, detections: [Detection]) async throws -> [PortionPrediction] }
protocol RemoteVisionService { func analyze(_ imageData: Data) async throws -> AnalysisResult }

enum ImagePreparation {
    static func prepare(_ data: Data, maxPixels: Int = 1280) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw AnalysisError.invalidImage }
        return image
    }
}

struct CoreMLIngredientRecognizer: IngredientRecognitionService {
    func recognize(_ image: CGImage) async throws -> [Detection] {
        guard let url = Bundle.main.url(forResource: "FoodRecognition", withExtension: "mlmodelc") else {
            throw AnalysisError.missingRecognitionModel
        }
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url))
        let request = VNCoreMLRequest(model: model)
        try VNImageRequestHandler(cgImage: image).perform([request])
        if let objects = request.results as? [VNRecognizedObjectObservation] {
            return objects.compactMap { observation in
                guard let label = observation.labels.first else { return nil }
                return Detection(name: label.identifier, canonicalID: label.identifier,
                                 confidence: Double(label.confidence), region: observation.boundingBox)
            }
        }
        if let labels = request.results as? [VNClassificationObservation] {
            return labels.prefix(5).map { Detection(name: $0.identifier, canonicalID: $0.identifier,
                                                     confidence: Double($0.confidence)) }
        }
        if let values = request.results as? [VNCoreMLFeatureValueObservation],
           let logits = values.first(where: { $0.featureName == "segmentation_logits" })?.featureValue.multiArrayValue,
           let url = Bundle.main.url(forResource: "food_labels", withExtension: "json"),
           let labels = try? JSONDecoder().decode([String].self, from: Data(contentsOf: url)) {
            return Self.decodeSegmentation(logits, labels: labels)
        }
        throw AnalysisError.unsupportedOutput
    }
    static func decodeSegmentation(_ array: MLMultiArray, labels: [String]) -> [Detection] {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] == labels.count else { return [] }
        let height = shape[2], width = shape[3], classes = shape[1]
        guard height > 0, width > 0 else { return [] }
        var counts = [Int](repeating: 0, count: classes)
        var left = [Int](repeating: width, count: classes), right = [Int](repeating: 0, count: classes)
        var top = [Int](repeating: height, count: classes), bottom = [Int](repeating: 0, count: classes)
        let stride = array.strides.map(\.intValue)
        for y in 0..<height { for x in 0..<width {
            var best = 0, score = -Double.infinity
            for c in 0..<classes {
                let offset = c * stride[1] + y * stride[2] + x * stride[3]
                let value = array[offset].doubleValue
                if value > score { score = value; best = c }
            }
            if best > 0 { counts[best] += 1; left[best] = min(left[best], x); right[best] = max(right[best], x)
                top[best] = min(top[best], y); bottom[best] = max(bottom[best], y) }
        } }
        return (1..<classes).compactMap { c in
            guard counts[c] >= max(8, width * height / 1000) else { return nil }
            let region = CGRect(x: Double(left[c]) / Double(width), y: Double(height - bottom[c] - 1) / Double(height),
                                width: Double(right[c] - left[c] + 1) / Double(width),
                                height: Double(bottom[c] - top[c] + 1) / Double(height))
            return Detection(name: labels[c].replacingOccurrences(of: "_", with: " ").capitalized,
                             canonicalID: labels[c], confidence: min(0.99, Double(counts[c]) / Double(width * height) * 3), region: region)
        }
    }
}

struct CoreMLPortionEstimator: PortionEstimationService {
    func estimate(_ image: CGImage, detections: [Detection]) async throws -> [PortionPrediction] {
        guard let url = Bundle.main.url(forResource: "FoodPortion", withExtension: "mlmodelc") else {
            throw AnalysisError.missingPortionModel
        }
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url))
        let request = VNCoreMLRequest(model: model)
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let values = request.results as? [VNCoreMLFeatureValueObservation] else {
            throw AnalysisError.unsupportedOutput
        }
        let map = Dictionary(uniqueKeysWithValues: values.map { observation in
            (observation.featureName, observation.featureValue.multiArrayValue?.firstScalar ?? observation.featureValue.doubleValue)
        })
        let totalMass = max(0, map["mass_g"] ?? 0)
        let estimate = Nutrition(calories: max(0, map["calories"] ?? 0),
                                 protein: max(0, map["protein"] ?? 0), carbs: max(0, map["carbs"] ?? 0),
                                 fat: max(0, map["fat"] ?? 0))
        guard totalMass > 0, !detections.isEmpty else { throw AnalysisError.unsupportedOutput }
        let share = 1.0 / Double(detections.count)
        return detections.map { PortionPrediction(canonicalID: $0.canonicalID, name: $0.name,
                                                  grams: totalMass * share, nutrition: estimate * share) }
    }
}

private extension MLMultiArray {
    var firstScalar: Double? { count > 0 ? self[0].doubleValue : nil }
}

struct PhotoAnalyzer {
    var recognition: IngredientRecognitionService = CoreMLIngredientRecognizer()
    var portion: PortionEstimationService = CoreMLPortionEstimator()
    var nutrition: NutritionRepository = BundledNutritionRepository()
    var remote: RemoteVisionService?
    func analyze(_ data: Data, progress: @escaping @MainActor (String) -> Void) async throws -> AnalysisResult {
        await progress("Image prepared")
        let image = try ImagePreparation.prepare(data)
        let detections: [Detection]
        do { detections = try await recognition.recognize(image) }
        catch {
            if let remote { return try await remote.analyze(data) }
            throw error
        }
        await progress("Foods identified")
        let portions = (try? await portion.estimate(image, detections: detections)) ?? detections.map {
            PortionPrediction(canonicalID: $0.canonicalID, name: $0.name, grams: 100, nutrition: .zero)
        }
        await progress("Calculating nutrition")
        let resolved = portions.map { item -> PortionPrediction in
            guard let id = item.canonicalID, let reference = nutrition.food(for: id) else { return item }
            return PortionPrediction(canonicalID: id, name: item.name, grams: item.grams,
                                     nutrition: reference.per100g * (item.grams / 100))
        }
        await progress("Preparing meal")
        return AnalysisResult(detections: detections, portions: resolved)
    }
    static func draft(from result: AnalysisResult) -> FoodDraft {
        var draft = FoodDraft()
        draft.name = result.detections.first?.name ?? "Photo food"
        draft.source = .photoAI
        draft.ingredients = result.portions.map { portion in
            var ingredient = IngredientDraft()
            ingredient.name = portion.name
            ingredient.quantity = max(1, portion.grams)
            ingredient.servingSize = 100
            ingredient.unit = .gram
            ingredient.nutrition = portion.grams > 0 ? portion.nutrition * (100 / portion.grams) : .zero
            ingredient.confidence = result.detections.first(where: { $0.name == portion.name })?.confidence
            ingredient.canonicalID = portion.canonicalID
            return ingredient
        }
        return draft
    }
}
