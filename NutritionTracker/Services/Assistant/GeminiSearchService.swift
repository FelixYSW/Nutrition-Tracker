import Foundation

/// Web search for the assistant, answered by Gemini with Google Search
/// grounding. Only the question text is sent - never photos, the chat or the
/// user's nutrition context - and the chat itself stays on OpenAI.
///
/// There is no fallback to another provider: without a search key, or when the
/// search fails, the assistant is told the search failed and carries on without
/// it. The model and key are set at build time (see `BundledAPIKey`).
struct GeminiSearchService: Sendable {

    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"
    /// Gemini models, in the order tried. Only Gemini 2.x has free Search
    /// grounding quota, and which names the API still serves can change, so a
    /// 404 moves on to the next one. `SEARCH_MODEL`, when set, is used alone.
    static let defaultModels = [
        "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
        // The family name on its own, in case the API accepts it, and the
        // always-current aliases, which only count if the names above are gone.
        "gemini-2.5", "gemini-pro-latest", "gemini-flash-latest"
    ]
    /// The model that last answered, tried first next time.
    private static let workingModelKey = "geminiSearch.workingModel"

    private let session: URLSession
    private let models: [String]

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }(),
         models: [String] = BundledAPIKey.searchModel.map { [$0] } ?? Self.defaultModels) {
        self.session = session
        self.models = models
    }

    var isConfigured: Bool { BundledAPIKey.hasSearchKey }

    func searchWeb(_ question: String) async throws -> WebSearchResult {
        let remembered = UserDefaults.standard.string(forKey: Self.workingModelKey)
        let order = models.contains { $0 == remembered }
            ? [remembered].compactMap { $0 } + models.filter { $0 != remembered }
            : models
        for model in order {
            do {
                let result = try await search(question, model: model)
                if models.count > 1 {
                    UserDefaults.standard.set(model, forKey: Self.workingModelKey)
                }
                return result
            } catch AssistantServiceError.modelUnavailable {
                // Not served to this key: nothing was run, so try the next.
                continue
            }
        }
        throw AssistantServiceError.requestFailed(
            detail: "none of the search models (\(order.joined(separator: ", "))) is available (HTTP 404)")
    }

    private func search(_ question: String, model: String) async throws -> WebSearchResult {
        guard let apiKey = BundledAPIKey.search else {
            throw AssistantServiceError.requestFailed(detail: "web search isn't available")
        }
        guard let url = URL(string: "\(Self.defaultBaseURL)/models/\(model):generateContent"),
              url.scheme == "https" else {
            throw AssistantServiceError.requestFailed(detail: "invalid search URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // In a header, not the URL, so the key never ends up in a logged address.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.makeBody(question: question))
        guard request.httpBody != nil else {
            throw AssistantServiceError.requestFailed(detail: "could not encode the search")
        }

        var (data, status) = try await perform(request)
        for delay in OpenAIAssistantService.busyRetryDelays where OpenAIAssistantService.isTransient(status) {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            (data, status) = try await perform(request)
        }
        // Gemini's 429 says which limit was hit (per-minute, per-day, or no free
        // quota for this model or tool); "rate limited" alone hid that.
        if status == 429 {
            let reason = OpenAIAssistantService.providerErrorMessage(from: data)
                .map { " - \($0)" } ?? ""
            throw AssistantServiceError.requestFailed(detail: "search HTTP 429\(reason)")
        }
        try OpenAIAssistantService.check(status: status, model: model, body: data)
        return try Self.decode(data: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let token = await AppActivity.shared.beginBackgroundWork(named: "Assistant search")
        do {
            let (data, response) = try await session.data(for: request)
            await AppActivity.shared.endBackgroundWork(token)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            await AppActivity.shared.endBackgroundWork(token)
            if let urlError = error as? URLError,
               urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
                throw AssistantServiceError.offline
            }
            throw AssistantServiceError.requestFailed(detail: error.localizedDescription)
        }
    }

    // MARK: Request and response

    /// Temperature 0, so the same question gets (nearly) the same answer.
    static func makeBody(question: String) -> [String: Any] {
        [
            "contents": [["role": "user", "parts": [["text": question]]]],
            "tools": [["google_search": [String: Any]()]],
            "generationConfig": ["temperature": 0]
        ]
    }

    private struct ResponseBody: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            struct Grounding: Decodable {
                struct Chunk: Decodable {
                    struct Web: Decodable {
                        let uri: String?
                        let title: String?
                    }
                    let web: Web?
                }
                let groundingChunks: [Chunk]?
            }
            let content: Content?
            let groundingMetadata: Grounding?
        }
        let candidates: [Candidate]?
    }

    /// The answer text and the pages it used, de-duplicated, with the link
    /// standing in for a missing title.
    static func decode(data: Data) throws -> WebSearchResult {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw AssistantServiceError.malformedResponse(detail: "unreadable search result")
        }
        let candidate = body.candidates?.first
        let summary = (candidate?.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw AssistantServiceError.malformedResponse(detail: "empty search result")
        }
        var seen = Set<String>()
        let sources = (candidate?.groundingMetadata?.groundingChunks ?? [])
            .compactMap { chunk -> WebSearchResult.Source? in
                guard let url = chunk.web?.uri, seen.insert(url).inserted else { return nil }
                let title = chunk.web?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(title: (title?.isEmpty == false) ? title! : url, url: url)
            }
        return WebSearchResult(summary: summary, sources: Array(sources.prefix(6)))
    }
}
