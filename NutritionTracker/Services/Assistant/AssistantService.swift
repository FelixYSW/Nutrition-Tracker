import Foundation

/// One turn in the conversation sent to the provider.
struct AssistantTurn: Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }

    enum Block: Equatable, Sendable {
        case text(String)
        /// JPEG bytes, for the menu-photo flow.
        case image(Data)
        case toolUse(id: String, name: String, input: [String: JSONValue])
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

    var errorDescription: String? {
        switch self {
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
    /// Overridable with the ASSISTANT_MODEL repository variable, because model
    /// names get retired. Check Google AI Studio for current names.
    static let defaultModel = "gemini-2.5-flash"

    private let session: URLSession
    private let baseURL: String
    private let model: String

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }(),
         baseURL: String = BundledAPIKey.assistantBaseURL ?? Self.defaultBaseURL,
         model: String = BundledAPIKey.assistantModel ?? Self.defaultModel) {
        self.session = session
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
    }

    var isConfigured: Bool {
        BundledAPIKey.hasAssistantKey
    }

    func send(turns: [AssistantTurn],
              contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {

        guard let apiKey = BundledAPIKey.assistant else {
            throw AssistantServiceError.notConfigured
        }
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError
            where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw AssistantServiceError.offline
        } catch {
            throw AssistantServiceError.requestFailed(detail: error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            // Free tiers rate-limit; this is the expected error under load.
            if http.statusCode == 429 { throw AssistantServiceError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                // Never include the body: it can echo the request, which holds
                // the user's nutrition context (spec section 39).
                throw AssistantServiceError.requestFailed(detail: "HTTP \(http.statusCode)")
            }
        }

        return try Self.decode(data: data)
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
            case .toolUse(let id, let name, let input):
                let arguments = (try? JSONSerialization.data(withJSONObject: unwrap(input)))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": arguments]
                ])
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
            calls.append(AssistantToolCall(id: id, tool: tool, arguments: arguments))
        }

        let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantResponse(text: (text?.isEmpty ?? true) ? nil : text, toolCalls: calls)
    }
}
