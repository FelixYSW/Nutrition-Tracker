import Foundation

/// One turn in the conversation sent to the provider.
struct AssistantTurn: Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    enum Block: Equatable, Codable, Sendable {
        case text(String)
        /// JPEG bytes, for the menu-photo flow.
        case image(Data)
        /// A PDF or plain-text file the user attached, e.g. a check-up report.
        case file(name: String, data: Data)
        /// `extra` is opaque provider data kept with the call. Unused by the
        /// OpenAI client; kept so chats saved by earlier versions still load.
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
            "The AI service is overloaded right now (HTTP \(status)). This is on the "
                + "provider's side and usually clears within a minute - try again shortly."
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

    /// Answers a question from a live web search, with the pages it used.
    func searchWeb(_ question: String) async throws -> WebSearchResult
}

extension AssistantServing {
    /// Providers without a search tool simply report that it isn't available.
    func searchWeb(_ question: String) async throws -> WebSearchResult {
        throw AssistantServiceError.requestFailed(detail: "web search isn't available")
    }
}

/// A written answer from a web search and the pages it came from.
struct WebSearchResult: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        var title: String
        var url: String
    }

    var summary: String
    var sources: [Source]
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


/// OpenAI Responses API client, with function tools and web search.
///
/// The Responses API rather than Chat Completions because GPT-6 Luna only
/// allows function calling in Chat Completions with reasoning turned off; the
/// assistant needs both its tools and (low-effort) reasoning. The model,
/// base URL and key are set at build time (see `BundledAPIKey`).
///
/// Every request is stateless (`store: false`): the conversation and the
/// user's nutrition context are sent each time and not kept by OpenAI as a
/// stored response, since they are health-adjacent data (spec section 39).
struct OpenAIAssistantService: AssistantServing {

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-6-luna"
    /// Enough thinking to follow the logging rules and plan tool calls, at a
    /// fraction of the cost and wait of the "medium" default. Reasoning
    /// tokens are billed as output.
    static let reasoningEffort = "low"

    private let session: URLSession
    private let baseURL: String
    private let model: String

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // A reply with photos plus reasoning can take over a minute.
        configuration.timeoutIntervalForRequest = 150
        // Reasoning plus a web search can take a while; allow for it.
        configuration.timeoutIntervalForResource = 180
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

    // MARK: Chat

    func send(turns: [AssistantTurn],
              contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {
        let body = Self.makeBody(model: model, turns: turns, contextJSON: contextJSON, tools: tools)
        let data = try await post(body)
        return try Self.decode(data: data)
    }

    // MARK: Web search

    /// One request with OpenAI's built-in web search tool. Separate from the
    /// chat request, so the chat keeps only its function tools and the
    /// answer comes back as a summary with the pages it cited.
    func searchWeb(_ question: String) async throws -> WebSearchResult {
        let data = try await post(Self.makeSearchBody(model: model, question: question))
        return try Self.decodeSearch(data: data)
    }

    // MARK: Transport

    private func post(_ body: [String: Any]) async throws -> Data {
        guard let apiKey = BundledAPIKey.assistant else {
            throw AssistantServiceError.notConfigured
        }
        guard let url = URL(string: "\(baseURL)/responses"), url.scheme == "https" else {
            throw AssistantServiceError.requestFailed(detail: "invalid assistant URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AssistantServiceError.requestFailed(detail: "could not encode the request")
        }

        // 500/502/503/504 mean the provider is briefly overloaded. These usually
        // clear within seconds, so retry a couple of times with a growing pause
        // before giving up. The request was never processed, so a retry can't
        // log anything twice.
        var (data, status) = try await perform(request)
        for delay in Self.busyRetryDelays where Self.isTransient(status) {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            (data, status) = try await perform(request)
        }
        try Self.check(status: status, model: model, body: data)
        return data
    }

    /// Pauses before each retry of a busy response, in seconds: three tries in
    /// about 6 seconds in all, short enough that the chat doesn't seem stuck.
    static let busyRetryDelays: [Double] = [1.5, 4]

    static func isTransient(_ status: Int) -> Bool {
        [500, 502, 503, 504].contains(status)
    }

    /// Sends one request. Switching to another app suspends this one and cuts
    /// the connection, which used to surface as "timed out" or "needs an
    /// internet connection". So iOS is asked for time to finish, and if the
    /// request still dies while the app was away, it's resent once the user
    /// is back. Resending is safe: each request is self-contained and nothing
    /// is saved without the user confirming a card.
    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let started = Date.now
            let token = await AppActivity.shared.beginBackgroundWork(named: "Assistant request")
            do {
                let (data, response) = try await session.data(for: request)
                await AppActivity.shared.endBackgroundWork(token)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                await AppActivity.shared.endBackgroundWork(token)
                let interruptedByBackground = await AppActivity.shared.wasBackgrounded(since: started)
                if interruptedByBackground, attempt < maxAttempts, !Task.isCancelled {
                    await AppActivity.shared.waitUntilActive()
                    continue
                }
                if let urlError = error as? URLError,
                   urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
                    throw AssistantServiceError.offline
                }
                throw AssistantServiceError.requestFailed(detail: error.localizedDescription)
            }
        }
        throw AssistantServiceError.requestFailed(detail: "the request could not be completed")
    }

    static func check(status: Int, model: String, body: Data? = nil) throws {
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

    /// `{"error": {"message": "..."}}`, or a top-level array of such objects,
    /// trimmed to one short line.
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

    // MARK: Request

    static func makeBody(model: String,
                         turns: [AssistantTurn],
                         contextJSON: String,
                         tools: [AssistantTool]) -> [String: Any] {
        // The context is rebuilt per request rather than kept as server-side
        // "memory", and travels with the instructions.
        [
            "model": model,
            "instructions": AssistantContextBuilder.systemPrompt
                + "\n\nCurrent user context as JSON:\n\(contextJSON)",
            "input": turns.flatMap(encode(turn:)),
            "tools": tools.map { tool in
                [
                    "type": "function",
                    "name": tool.rawValue,
                    "description": tool.description,
                    "parameters": tool.inputSchema,
                    // The schemas use optional fields, which strict mode
                    // doesn't allow.
                    "strict": false
                ] as [String: Any]
            },
            "reasoning": ["effort": reasoningEffort],
            "store": false
        ]
    }


    static func makeSearchBody(model: String, question: String) -> [String: Any] {
        [
            "model": model,
            "input": question,
            "tools": [["type": "web_search"]],
            "reasoning": ["effort": reasoningEffort],
            "store": false
        ]
    }

    /// One app turn becomes one or more Responses input items: a message for
    /// any text or photos, a `function_call` per tool call, and a
    /// `function_call_output` per tool result.
    ///
    /// Function calls are sent without their response item ids: with those,
    /// the API expects the matching reasoning items too, which a stateless
    /// client doesn't keep.
    static func encode(turn: AssistantTurn) -> [[String: Any]] {
        var items: [[String: Any]] = []
        var texts: [String] = []
        var images: [Data] = []
        var files: [[String: Any]] = []
        var calls: [[String: Any]] = []
        var results: [[String: Any]] = []

        for block in turn.blocks {
            switch block {
            case .text(let text):
                texts.append(text)
            case .image(let data):
                images.append(data)
            case .file(let name, let data):
                files.append(filePart(name: name, data: data))
            case .toolUse(let id, let name, let input, _):
                let arguments = (try? JSONSerialization.data(withJSONObject: unwrap(input)))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                calls.append(["type": "function_call", "call_id": id,
                              "name": name, "arguments": arguments])
            case .toolResult(let id, let content, _):
                results.append(["type": "function_call_output", "call_id": id, "output": content])
            }
        }

        let text = texts.joined(separator: "\n\n")
        switch turn.role {
        case .assistant:
            if !text.isEmpty { items.append(["role": "assistant", "content": text]) }
            items.append(contentsOf: calls)

        case .user:
            // Results first: they answer the calls in the previous turn.
            items.append(contentsOf: results)
            if !images.isEmpty || !files.isEmpty {
                var parts: [[String: Any]] = images.map { data in
                    ["type": "input_image",
                     "image_url": "data:image/jpeg;base64,\(data.base64EncodedString())"]
                }
                parts.append(contentsOf: files)
                if !text.isEmpty { parts.append(["type": "input_text", "text": text]) }
                items.append(["role": "user", "content": parts])
            } else if !text.isEmpty {
                items.append(["role": "user", "content": text])
            }
        }
        return items
    }

    /// A PDF goes up as an `input_file`; any other file is plain text and is
    /// sent as text under its file name.
    static func filePart(name: String, data: Data) -> [String: Any] {
        if name.lowercased().hasSuffix(".pdf") {
            return ["type": "input_file",
                    "filename": name,
                    "file_data": "data:application/pdf;base64,\(data.base64EncodedString())"]
        }
        let body = String(decoding: data, as: UTF8.self)
        return ["type": "input_text", "text": "[Attached file: \(name)]\n\(body)"]
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

    /// The parts of a Responses API reply the app reads. Reasoning and web
    /// search items are skipped.
    private struct ResponseBody: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                struct Annotation: Decodable {
                    let type: String?
                    let url: String?
                    let title: String?
                }
                let type: String?
                let text: String?
                let annotations: [Annotation]?
            }
            let type: String
            let content: [Content]?
            let call_id: String?
            let name: String?
            /// Normally a JSON-encoded string; an object is accepted too.
            let arguments: JSONValue?
        }
        let output: [Item]
    }

    private static func decodeBody(_ data: Data) throws -> ResponseBody {
        do {
            return try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw AssistantServiceError.malformedResponse(detail: "unreadable envelope")
        }
    }

    /// All `output_text` of the reply's message items, joined.
    private static func outputText(_ body: ResponseBody) -> String {
        body.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(data: Data) throws -> AssistantResponse {
        let body = try decodeBody(data)

        var calls: [AssistantToolCall] = []
        for (index, item) in body.output.enumerated() where item.type == "function_call" {
            // A hallucinated tool name is dropped here rather than being passed
            // down to the executor (spec section 34).
            guard let name = item.name, let tool = AssistantTool(rawValue: name) else { continue }

            let arguments: [String: JSONValue]
            switch item.arguments {
            case .string(let json):
                arguments = (try? JSONDecoder().decode([String: JSONValue].self,
                                                       from: Data(json.utf8))) ?? [:]
            case .object(let object):
                arguments = object
            default:
                arguments = [:]
            }

            // An id is needed to pair the result with its call.
            let id = (item.call_id?.isEmpty == false)
                ? item.call_id! : "call_\(index)_\(UUID().uuidString.prefix(8))"
            calls.append(AssistantToolCall(id: id, tool: tool, arguments: arguments))
        }

        let text = outputText(body)
        guard !text.isEmpty || !calls.isEmpty || body.output.contains(where: { $0.type == "message" })
        else {
            throw AssistantServiceError.malformedResponse(detail: "no reply")
        }
        return AssistantResponse(text: text.isEmpty ? nil : text, toolCalls: calls)
    }

    static func decodeSearch(data: Data) throws -> WebSearchResult {
        let body = try decodeBody(data)
        let summary = outputText(body)
        guard !summary.isEmpty else {
            throw AssistantServiceError.malformedResponse(detail: "empty search result")
        }
        var seen = Set<String>()
        let sources = body.output
            .flatMap { $0.content ?? [] }
            .flatMap { $0.annotations ?? [] }
            .compactMap { annotation -> WebSearchResult.Source? in
                guard annotation.type == "url_citation", let url = annotation.url,
                      seen.insert(url).inserted else { return nil }
                let title = annotation.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(title: (title?.isEmpty == false) ? title! : url, url: url)
            }
        return WebSearchResult(summary: summary, sources: Array(sources.prefix(6)))
    }
}
