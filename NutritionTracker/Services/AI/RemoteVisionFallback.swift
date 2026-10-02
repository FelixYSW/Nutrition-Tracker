import Foundation

/// Optional remote vision fallback (spec section 25).
///
/// Behind a protocol so the app compiles and runs with nothing configured. It is
/// used only when the local models are missing or produced nothing usable, and
/// never without the user having supplied a key.
protocol RemoteVisionService: Sendable {
    var isConfigured: Bool { get }
    func identifyFoods(in image: PreparedImage) async throws -> IngredientRecognitionOutput
}

/// Does nothing, reports that it is unconfigured. The default.
struct DisabledRemoteVisionService: RemoteVisionService {
    var isConfigured: Bool { false }

    func identifyFoods(in image: PreparedImage) async throws -> IngredientRecognitionOutput {
        throw AIServiceError.remoteFallbackNotConfigured
    }
}

/// Remote fallback implemented against the Anthropic Messages API.
///
/// Provider-agnostic at the protocol level: swapping in another vendor means
/// adding a sibling type, not touching the pipeline.
struct AnthropicRemoteVisionService: RemoteVisionService {

    private let session: URLSession
    private let ontology: FoodOntology
    private let model: String

    init(session: URLSession = .shared,
         ontology: FoodOntology = .shared,
         model: String = "claude-sonnet-5-5") {
        self.session = session
        self.ontology = ontology
        self.model = model
    }

    var isConfigured: Bool {
        APIKeyResolver.hasKey(for: .remoteVisionAPIKey)
    }

    func identifyFoods(in image: PreparedImage) async throws -> IngredientRecognitionOutput {
        guard let apiKey = APIKeyResolver.key(for: .remoteVisionAPIKey), !apiKey.isEmpty else {
            throw AIServiceError.remoteFallbackNotConfigured
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let payload = RequestBody(
            model: model,
            max_tokens: 1024,
            messages: [
                .init(role: "user", content: [
                    .init(type: "image", text: nil, source: .init(
                        type: "base64",
                        media_type: "image/jpeg",
                        data: image.jpegData.base64EncodedString())),
                    .init(type: "text", text: Self.prompt, source: nil)
                ])
            ])

        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIServiceError.remoteRequestFailed(detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.remoteRequestFailed(detail: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The body may contain the key in an echoed request; never log it.
            throw AIServiceError.remoteRequestFailed(detail: "HTTP \(http.statusCode)")
        }

        return try decode(data: data)
    }

    private func decode(data: Data) throws -> IngredientRecognitionOutput {
        let envelope: ResponseBody
        do {
            envelope = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw AIServiceError.unsupportedModelOutput(detail: "unreadable response envelope")
        }

        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw AIServiceError.unsupportedModelOutput(detail: "no text block in response")
        }

        // The model is asked for bare JSON, but tolerate it being wrapped in a
        // fenced code block, which happens often enough to be worth handling.
        let json = Self.extractJSON(from: text)
        guard let jsonData = json.data(using: .utf8) else {
            throw AIServiceError.unsupportedModelOutput(detail: "non-UTF8 payload")
        }

        struct Detected: Codable {
            let name: String
            let confidence: Double?
            let area_fraction: Double?
        }
        struct Payload: Codable { let foods: [Detected] }

        let parsed: Payload
        do {
            parsed = try JSONDecoder().decode(Payload.self, from: jsonData)
        } catch {
            throw AIServiceError.unsupportedModelOutput(detail: "malformed food list")
        }

        let detections = parsed.foods.compactMap { food -> DetectedIngredient? in
            let name = food.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let mapped = ontology.resolve(rawLabel: name)
            return DetectedIngredient(
                rawLabel: name,
                canonicalID: mapped?.canonicalID,
                displayName: mapped?.displayName ?? name.humanisedLabel,
                // A remote model's self-reported confidence is soft; clamp it
                // and never let a missing value read as certainty.
                confidence: min(max(food.confidence ?? 0.5, 0), 1),
                boundingBox: nil,
                areaFraction: food.area_fraction)
        }

        return IngredientRecognitionOutput(detections: detections,
                                           modelIdentifier: "remote:\(model)")
    }

    static func extractJSON(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else {
            return text
        }
        return String(text[start...end])
    }

    private static let prompt = """
    Identify the distinct foods and ingredients visible in this photo.

    Reply with bare JSON only, no prose and no code fence, in exactly this shape:
    {"foods": [{"name": "white rice", "confidence": 0.9, "area_fraction": 0.4}]}

    Rules:
    - One entry per distinct food or ingredient you can actually see.
    - "confidence" is 0 to 1, reflecting how sure you are of the identification.
    - "area_fraction" is roughly how much of the plate that food covers, 0 to 1.
    - Use plain lowercase English food names.
    - Do not estimate nutrition or mass; only identify what is there.
    - If you cannot identify any food, reply {"foods": []}.
    """

    // MARK: Wire types

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let messages: [Message]

        struct Message: Encodable {
            let role: String
            let content: [Block]
        }

        struct Block: Encodable {
            let type: String
            let text: String?
            let source: Source?
        }

        struct Source: Encodable {
            let type: String
            let media_type: String
            let data: String
        }
    }

    private struct ResponseBody: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }
}
