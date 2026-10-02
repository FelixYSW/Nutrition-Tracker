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
    case notConfigured
    case optInRequired
    case offline
    case requestFailed(detail: String)
    case malformedResponse(detail: String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add an API key in Settings to use the assistant."
        case .optInRequired:
            "Turn on assistant data sharing in Settings to use the assistant."
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

    var isSetupIssue: Bool {
        self == .notConfigured || self == .optInRequired
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

/// Reports unconfigured. Used so the UI can render a "needs setup" state without
/// branching on an optional service.
struct UnconfiguredAssistantService: AssistantServing {
    var isConfigured: Bool { false }

    func send(turns: [AssistantTurn], contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {
        throw AssistantServiceError.notConfigured
    }
}

/// Anthropic Messages API implementation with tool use.
struct AnthropicAssistantService: AssistantServing {

    private let session: URLSession
    private let model: String

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }(),
         model: String = "claude-sonnet-5-5") {
        self.session = session
        self.model = model
    }

    var isConfigured: Bool {
        APIKeyResolver.hasKey(for: .assistantAPIKey)
    }

    func send(turns: [AssistantTurn],
              contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {

        guard let apiKey = APIKeyResolver.key(for: .assistantAPIKey), !apiKey.isEmpty else {
            throw AssistantServiceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = makeBody(turns: turns, contextJSON: contextJSON, tools: tools)
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
            if http.statusCode == 429 { throw AssistantServiceError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                // Never include the body: it can echo the request, which holds
                // the user's nutrition context (spec section 39).
                throw AssistantServiceError.requestFailed(detail: "HTTP \(http.statusCode)")
            }
        }

        return try Self.decode(data: data)
    }

    private func makeBody(turns: [AssistantTurn],
                          contextJSON: String,
                          tools: [AssistantTool]) -> [String: Any] {
        var system: [[String: Any]] = [
            ["type": "text", "text": AssistantContextBuilder.systemPrompt]
        ]
        // The context goes in the system block, rebuilt per request rather than
        // accumulated as server-side "memory".
        system.append(["type": "text",
                       "text": "Current user context as JSON:\n\(contextJSON)"])

        return [
            "model": model,
            "max_tokens": 1536,
            "system": system,
            "tools": tools.map { tool in
                [
                    "name": tool.rawValue,
                    "description": tool.description,
                    "input_schema": tool.inputSchema
                ] as [String: Any]
            },
            "messages": turns.map(Self.encode(turn:))
        ]
    }

    private static func encode(turn: AssistantTurn) -> [String: Any] {
        var content: [[String: Any]] = []
        for block in turn.blocks {
            switch block {
            case .text(let text):
                content.append(["type": "text", "text": text])

            case .image(let data):
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": data.base64EncodedString()
                    ]
                ])

            case .toolUse(let id, let name, let input):
                content.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": unwrap(input)
                ])

            case .toolResult(let id, let resultContent, let isError):
                content.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": resultContent,
                    "is_error": isError
                ])
            }
        }
        return ["role": turn.role.rawValue, "content": content]
    }

    /// `JSONValue` -> plain Foundation objects for JSONSerialization.
    private static func unwrap(_ input: [String: JSONValue]) -> [String: Any] {
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

    static func decode(data: Data) throws -> AssistantResponse {
        struct Body: Decodable {
            let content: [Block]
            struct Block: Decodable {
                let type: String
                let text: String?
                let id: String?
                let name: String?
                let input: [String: JSONValue]?
            }
        }

        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw AssistantServiceError.malformedResponse(detail: "unreadable envelope")
        }

        var text: [String] = []
        var calls: [AssistantToolCall] = []

        for block in body.content {
            switch block.type {
            case "text":
                if let value = block.text, !value.isEmpty { text.append(value) }

            case "tool_use":
                // A hallucinated tool name is dropped here rather than being
                // passed down to the executor (spec section 34).
                guard let id = block.id,
                      let name = block.name,
                      let tool = AssistantTool(rawValue: name) else {
                    continue
                }
                calls.append(AssistantToolCall(id: id, tool: tool,
                                               arguments: block.input ?? [:]))

            default:
                continue
            }
        }

        return AssistantResponse(text: text.isEmpty ? nil : text.joined(separator: "\n\n"),
                                 toolCalls: calls)
    }
}
