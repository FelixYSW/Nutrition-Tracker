import Foundation

/// One turn in the conversation sent to the provider.
struct AssistantTurn: Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }

    enum Block: Equatable, Sendable {
        case text(String)
        /// JPEG bytes, for the menu-photo flow.
        case image(Data)
        /// `extra` is provider data that must be sent back unchanged with the
        /// call - for Gemini, the thought signature.
        case toolUse(id: String, name: String, input: [String: JSONValue], extra: JSONValue? = nil)
        case toolResult(id: String, content: String, isError: Bool)
    }

    var role: Role
    var blocks: [Block]

    static func user(_ text: String) -> AssistantTurn {
        AssistantTurn(role: .user, blocks: [.text(text)])
    }
}

/// What the model replied with.
struct AssistantResponse: Equatable, Sendable {
    var text: String?
    var toolCalls: [AssistantToolCall]

    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

enum AssistantServiceError: LocalizedError, Equatable {
    /// The build has no assistant key. Not something the user can fix.
    case notConfigured
    case offline
    case requestFailed(detail: String)
    case malformedResponse(detail: String)
    case rateLimited
    /// 500/502/503/504 that persisted through the automatic retries.
    case providerBusy(status: Int)
    /// HTTP 404: the configured model name doesn't exist (retired or mistyped),
    /// and no replacement could be found automatically.
    case modelUnavailable(model: String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let model):
            "The AI model \"\(model)\" isn't available (HTTP 404)."
        case .notConfigured:
            "The assistant isn't available in this version of the app."
        case .offline:
            "The assistant needs an internet connection."
        case .requestFailed(let detail):
            "The assistant request failed: \(detail)"
        case .malformedResponse(let detail):
            "The assistant sent a reply this app could not read: \(detail)"
        case .rateLimited:
            "The AI provider is rate limiting requests. Try again shortly."
        case .providerBusy(let status):
            "Gemini is overloaded right now (HTTP \(status)). This is on Google's side "
                + "and usually clears within a minute - try again shortly."
        }
    }
}

/// Provider-agnostic assistant interface (spec section 29A).
protocol AssistantServing: Sendable {
    var isConfigured: Bool { get }

    /// Sends the conversation plus the freshly built context and returns the
    /// model's reply, including any tool calls it wants to make.
    func send(turns: [AssistantTurn],
              contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse
}

/// Reports unconfigured. Used so the UI can render an "unavailable" state without
/// branching on an optional service.
struct UnconfiguredAssistantService: AssistantServing {
    var isConfigured: Bool { false }

    func send(turns: [AssistantTurn], contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {
        throw AssistantServiceError.notConfigured
    }
}

/// Chat Completions client for any OpenAI-compatible API, with tool calling.
///
/// Defaults to Google Gemini's OpenAI-compatible endpoint. Pointing it at
/// another compatible provider (DeepSeek, Groq, OpenRouter, ...) only needs a
/// different base URL and model name, both of which can be set at build time
/// without code changes (see `BundledAPIKey`).
struct OpenAICompatibleAssistantService: AssistantServing {

    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    /// Starting model for every install: Flash-Lite, chosen for its much higher
    /// free-tier daily limit (the app shares one key). Google retires model
    /// names, so if this (or a remembered model) returns 404, the service looks
    /// up the current list and switches to the newest Flash-Lite automatically.
    /// ASSISTANT_MODEL, if set, pins a model instead.
    static let defaultModel = "gemini-3.5-flash-lite"

    /// Where an auto-discovered model is remembered between launches. The "v2"
    /// suffix makes installs forget a model remembered before the switch to
    /// Flash-Lite (e.g. a full Flash model with a 20-a-day limit).
    static let discoveredModelKey = "assistant.discoveredModel.v2"

    private let session: URLSession
    private let baseURL: String
    /// Set when ASSISTANT_MODEL was provided at build time; never overridden.
    private let pinnedModel: String?
    /// Looked up when needed rather than stored: UserDefaults is thread-safe
    /// but not marked Sendable, and this struct must be (Swift 6).
    private var defaults: UserDefaults { .standard }

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }(),
         baseURL: String = BundledAPIKey.assistantBaseURL ?? Self.defaultBaseURL,
         pinnedModel: String? = BundledAPIKey.assistantModel) {
        self.session = session
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.pinnedModel = pinnedModel
    }

    var isConfigured: Bool {
        BundledAPIKey.hasAssistantKey
    }

    /// Pinned model, else the last model that was discovered to work, else the default.
    private var currentModel: String {
        pinnedModel ?? defaults.string(forKey: Self.discoveredModelKey) ?? Self.defaultModel
    }

    func send(turns: [AssistantTurn],
              contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {

        guard let apiKey = BundledAPIKey.assistant else {
            throw AssistantServiceError.notConfigured
        }

        let model = currentModel
        let (data, status) = try await postChat(model: model, apiKey: apiKey, turns: turns,
                                                contextJSON: contextJSON, tools: tools)

        // 404 means the model name no longer exists. Unless it was pinned on
        // purpose, find a current one, remember it, and retry once.
        if status == 404 {
            if pinnedModel != nil {
                throw AssistantServiceError.requestFailed(
                    detail: "the model \"\(model)\" was not found (HTTP 404). It is set by "
                        + "the ASSISTANT_MODEL variable: change it to a current model name, "
                        + "or delete the variable so the app picks one itself.")
            }
            guard let replacement = try await discoverModel(apiKey: apiKey, excluding: model) else {
                throw AssistantServiceError.requestFailed(
                    detail: "the model \"\(model)\" was not found (HTTP 404), and the "
                        + "provider's model list offered no replacement.")
            }
            let (retryData, retryStatus) = try await postChat(model: replacement, apiKey: apiKey,
                                                              turns: turns, contextJSON: contextJSON,
                                                              tools: tools)
            try Self.check(status: retryStatus, model: replacement, body: retryData)
            // Remembered only once it has actually worked, so a bad pick is
            // never stuck as the starting model.
            defaults.set(replacement, forKey: Self.discoveredModelKey)
            return try Self.decode(data: retryData)
        }

        try Self.check(status: status, model: model, body: data)
        return try Self.decode(data: data)
    }

    private func postChat(model: String, apiKey: String, turns: [AssistantTurn],
                          contextJSON: String, tools: [AssistantTool]) async throws -> (Data, Int) {
        guard let url = URL(string: "\(baseURL)/chat/completions"), url.scheme == "https" else {
            throw AssistantServiceError.requestFailed(detail: "invalid assistant URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = Self.makeBody(model: model, turns: turns, contextJSON: contextJSON, tools: tools)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AssistantServiceError.requestFailed(detail: "could not encode the request")
        }

        // 500/502/503/504 mean the provider is briefly overloaded (Gemini's free
        // tier sends 503 "model is overloaded" at busy times). These usually
        // clear within seconds, so retry a couple of times with a growing pause
        // before giving up. The request was never processed, so a retry can't
        // log anything twice.
        var result = try await perform(request)
        for delay in Self.busyRetryDelays where Self.isTransient(result.1) {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            result = try await perform(request)
        }
        return result
    }

    /// Pauses before each retry of a busy response, in seconds: three tries in
    /// about 6 seconds in all, short enough that the chat doesn't seem stuck.
    static let busyRetryDelays: [Double] = [1.5, 4]

    static func isTransient(_ status: Int) -> Bool {
        [500, 502, 503, 504].contains(status)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError
            where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw AssistantServiceError.offline
        } catch {
            throw AssistantServiceError.requestFailed(detail: error.localizedDescription)
        }
    }

    static func check(status: Int, model: String, body: Data? = nil) throws {
        // Free tiers rate-limit; this is the expected error under load.
        if status == 429 { throw AssistantServiceError.rateLimited }
        if isTransient(status) { throw AssistantServiceError.providerBusy(status: status) }
        if status == 404 { throw AssistantServiceError.modelUnavailable(model: model) }
        guard (200..<300).contains(status) else {
            // Only the provider's short error message is shown, never the raw
            // body, which could echo the user's nutrition context (spec 39).
            let reason = providerErrorMessage(from: body).map { " - \($0)" } ?? ""
            throw AssistantServiceError.requestFailed(detail: "HTTP \(status)\(reason)")
        }
    }

    /// `{"error": {"message": "..."}}` (OpenAI and Gemini) or a top-level
    /// array of such objects, trimmed to one short line.
    static func providerErrorMessage(from body: Data?) -> String? {
        guard let body,
              let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return nil }
        let root = json.arrayValue?.first ?? json
        guard let message = root.objectValue?["error"]?.objectValue?["message"]?.stringValue else {
            return nil
        }
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return line.count > 160 ? String(line.prefix(160)) + "\u{2026}" : line
    }

    // MARK: Model discovery

    /// Asks the provider which models exist and picks one suitable for chat.
    private func discoverModel(apiKey: String, excluding failed: String) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/models") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await perform(request)
        guard (200..<300).contains(status) else { return nil }

        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        return Self.pickModel(from: list.data.map(\.id), excluding: failed)
    }

    /// Chooses the best general chat model from a provider's model list.
    ///
    /// Prefers Gemini Flash-Lite (highest free daily limit), then Flash, stable over
    /// preview, newest version first. Specialised models
    /// (embedding, image, audio, TTS, live) are skipped.
    static func pickModel(from ids: [String], excluding failed: String) -> String? {
        let skip = ["embed", "image", "tts", "audio", "live", "vision", "aqa", "imagen", "veo", "learnlm", "gemma"]
        let candidates = ids
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .filter { id in
                let lower = id.lowercased()
                return id != failed && lower.contains("gemini") && !skip.contains { lower.contains($0) }
            }

        func version(_ id: String) -> Double {
            // "gemini-3.1-flash" -> 3.1
            let parts = id.lowercased().split(separator: "-")
            guard let index = parts.firstIndex(of: "gemini"), index + 1 < parts.count else { return 0 }
            return Double(parts[index + 1]) ?? 0
        }
        func isPreview(_ id: String) -> Bool {
            let lower = id.lowercased()
            return lower.contains("preview") || lower.contains("exp")
        }

        /// 0 Flash-Lite (highest free daily limit), 1 Flash, 2 anything else.
        func family(_ id: String) -> Int {
            let lower = id.lowercased()
            if lower.contains("flash-lite") || lower.contains("flash_lite") { return 0 }
            if lower.contains("flash") { return 1 }
            return 2
        }

        let ranked = candidates.sorted { lhs, rhs in
            if family(lhs) != family(rhs) { return family(lhs) < family(rhs) }
            if isPreview(lhs) != isPreview(rhs) { return !isPreview(lhs) }
            if version(lhs) != version(rhs) { return version(lhs) > version(rhs) }
            return lhs < rhs
        }
        return ranked.first
    }

    // MARK: Request

    static func makeBody(model: String,
                         turns: [AssistantTurn],
                         contextJSON: String,
                         tools: [AssistantTool]) -> [String: Any] {
        // The context is rebuilt per request rather than kept as server-side
        // "memory", and travels in the system message.
        var messages: [[String: Any]] = [[
            "role": "system",
            "content": AssistantContextBuilder.systemPrompt
                + "\n\nCurrent user context as JSON:\n\(contextJSON)"
        ]]
        for turn in turns {
            messages.append(contentsOf: encode(turn: turn))
        }

        return [
            "model": model,
            "messages": messages,
            "tools": tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.rawValue,
                        "description": tool.description,
                        "parameters": tool.inputSchema
                    ] as [String: Any]
                ] as [String: Any]
            }
        ]
    }

    /// One app turn can become several Chat Completions messages: each tool
    /// result is its own "tool" message, and tool calls ride on the assistant
    /// message.
    static func encode(turn: AssistantTurn) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var texts: [String] = []
        var images: [Data] = []
        var toolCalls: [[String: Any]] = []

        for block in turn.blocks {
            switch block {
            case .text(let text):
                texts.append(text)
            case .image(let data):
                images.append(data)
            case .toolUse(let id, let name, let input, let extra):
                let arguments = (try? JSONSerialization.data(withJSONObject: unwrap(input)))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                var call: [String: Any] = [
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": arguments]
                ]
                // Gemini's thought signature, sent back exactly as received.
                if let extra { call["extra_content"] = unwrap(value: extra) }
                toolCalls.append(call)
            case .toolResult(let id, let content, _):
                messages.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }

        let text = texts.joined(separator: "\n\n")
        switch turn.role {
        case .assistant:
            guard !text.isEmpty || !toolCalls.isEmpty else { break }
            var message: [String: Any] = ["role": "assistant"]
            // Omitted rather than null when empty: not every compatible API
            // accepts a null content alongside tool calls.
            if !text.isEmpty { message["content"] = text }
            if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
            messages.append(message)

        case .user:
            if !images.isEmpty {
                var parts: [[String: Any]] = images.map { data in
                    ["type": "image_url",
                     "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]]
                }
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                messages.append(["role": "user", "content": parts])
            } else if !text.isEmpty {
                messages.append(["role": "user", "content": text])
            }
        }
        return messages
    }

    /// `JSONValue` -> plain Foundation objects for JSONSerialization.
    static func unwrap(_ input: [String: JSONValue]) -> [String: Any] {
        input.mapValues(unwrap(value:))
    }

    private static func unwrap(value: JSONValue) -> Any {
        switch value {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .array(let values): values.map(unwrap(value:))
        case .object(let values): unwrap(values)
        case .null: NSNull()
        }
    }

    // MARK: Response

    static func decode(data: Data) throws -> AssistantResponse {
        struct Body: Decodable {
            struct Choice: Decodable { let message: Message }
            struct Message: Decodable {
                let content: String?
                let tool_calls: [ToolCall]?
            }
            struct ToolCall: Decodable {
                let id: String?
                let function: Function
                /// Gemini: `{"google": {"thought_signature": "..."}}`.
                let extra_content: JSONValue?
            }
            struct Function: Decodable {
                let name: String
                /// Normally a JSON-encoded string; some compatible APIs send an
                /// object instead, so both are accepted.
                let arguments: JSONValue?
            }
            let choices: [Choice]
        }

        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw AssistantServiceError.malformedResponse(detail: "unreadable envelope")
        }
        guard let message = body.choices.first?.message else {
            throw AssistantServiceError.malformedResponse(detail: "no choices")
        }

        var calls: [AssistantToolCall] = []
        for (index, call) in (message.tool_calls ?? []).enumerated() {
            // A hallucinated tool name is dropped here rather than being passed
            // down to the executor (spec section 34).
            guard let tool = AssistantTool(rawValue: call.function.name) else { continue }

            let arguments: [String: JSONValue]
            switch call.function.arguments {
            case .string(let json):
                arguments = (try? JSONDecoder().decode([String: JSONValue].self,
                                                       from: Data(json.utf8))) ?? [:]
            case .object(let object):
                arguments = object
            default:
                arguments = [:]
            }

            // Some compatible APIs omit ids; one is needed to pair the result.
            let id = (call.id?.isEmpty == false) ? call.id! : "call_\(index)_\(UUID().uuidString.prefix(8))"
            calls.append(AssistantToolCall(id: id, tool: tool, arguments: arguments,
                                           extra: call.extra_content))
        }

        let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantResponse(text: (text?.isEmpty ?? true) ? nil : text, toolCalls: calls)
    }
}
