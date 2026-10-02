import Foundation
import SwiftData
import Observation

/// A message as shown in the chat transcript.
struct AssistantChatMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        /// A write awaiting confirmation, rendered as a card.
        case proposal(PendingAssistantWrite)
        /// Resolution of a proposal, so the transcript keeps a record.
        case proposalResolved(summary: String, confirmed: Bool)
        case error(String)
        case toolActivity(String)
    }

    let id = UUID()
    var kind: Kind
    var timestamp: Date = .now
}

/// Drives the assistant sheet (spec section 29A).
///
/// Holds the tool-call loop: send -> model replies with tool calls -> read tools
/// run immediately -> write tools surface a confirmation card and the loop
/// pauses until the user decides.
@MainActor
@Observable
final class AssistantViewModel {

    private(set) var messages: [AssistantChatMessage] = []
    private(set) var isSending = false
    /// The single write currently awaiting confirmation. Only one at a time, so
    /// the user is never asked to approve a batch they cannot inspect.
    private(set) var pendingWrite: PendingAssistantWrite?

    var composerText = ""
    /// Menu photo attached to the next message.
    var attachedImageData: Data?

    private var turns: [AssistantTurn] = []
    /// Tool results queued while a confirmation is outstanding.
    private var deferredResults: [AssistantTurn.Block] = []

    private let service: AssistantServing
    private let executor: AssistantToolExecutor
    private let contextBuilder: AssistantContextBuilder
    private let settings: AppSettings

    /// Guards against an unbounded tool loop if the model keeps calling tools.
    private static let maxToolRoundTrips = 5

    init(service: AssistantServing,
         executor: AssistantToolExecutor,
         contextBuilder: AssistantContextBuilder,
         settings: AppSettings) {
        self.service = service
        self.executor = executor
        self.contextBuilder = contextBuilder
        self.settings = settings
    }

    @MainActor
    static func make(context: ModelContext, settings: AppSettings) -> AssistantViewModel {
        let service: AssistantServing = APIKeyResolver.hasKey(for: .assistantAPIKey)
            ? AnthropicAssistantService()
            : UnconfiguredAssistantService()

        return AssistantViewModel(
            service: service,
            executor: AssistantToolExecutor(context: context),
            contextBuilder: AssistantContextBuilder(context: context),
            settings: settings)
    }

    // MARK: Availability

    enum Availability: Equatable {
        case ready
        case needsOptIn
        case needsAPIKey

        var isReady: Bool { self == .ready }
    }

    var availability: Availability {
        if !settings.assistantDataSharingOptIn { return .needsOptIn }
        if !service.isConfigured { return .needsAPIKey }
        return .ready
    }

    var canSend: Bool {
        availability.isReady
            && !isSending
            && pendingWrite == nil
            && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || attachedImageData != nil)
    }

    // MARK: Sending

    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImageData
        guard !text.isEmpty || image != nil else { return }

        guard availability.isReady else {
            append(.error(availability == .needsOptIn
                ? AssistantServiceError.optInRequired.localizedDescription
                : AssistantServiceError.notConfigured.localizedDescription))
            return
        }

        composerText = ""
        attachedImageData = nil

        var blocks: [AssistantTurn.Block] = []
        if let image { blocks.append(.image(image)) }
        if !text.isEmpty { blocks.append(.text(text)) }
        turns.append(AssistantTurn(role: .user, blocks: blocks))

        append(.user(text.isEmpty ? "[menu photo]" : text))
        await runLoop()
    }

    /// Sends the conversation and processes tool calls until the model stops
    /// calling tools or a confirmation is required.
    private func runLoop() async {
        isSending = true
        defer { isSending = false }

        for _ in 0..<Self.maxToolRoundTrips {
            let contextJSON: String
            do {
                contextJSON = try contextBuilder.encodedJSON()
            } catch {
                append(.error("Could not assemble your nutrition context."))
                return
            }

            let response: AssistantResponse
            do {
                response = try await service.send(turns: turns,
                                                   contextJSON: contextJSON,
                                                   tools: AssistantTool.allCases)
            } catch let error as AssistantServiceError {
                append(.error(error.localizedDescription))
                return
            } catch {
                append(.error(error.localizedDescription))
                return
            }

            if let text = response.text {
                append(.assistant(text))
            }

            guard response.hasToolCalls else { return }

            // Record the assistant turn verbatim so the provider sees its own
            // tool_use blocks on the next round trip.
            turns.append(AssistantTurn(role: .assistant, blocks: response.toolCalls.map {
                .toolUse(id: $0.id, name: $0.tool.rawValue, input: $0.arguments)
            }))

            var resultBlocks: [AssistantTurn.Block] = []
            var paused = false

            for call in response.toolCalls {
                if paused {
                    // Anything after a confirmation request is deferred: the
                    // provider requires a result for every tool_use block, and
                    // we cannot answer them until the user has decided.
                    resultBlocks.append(.toolResult(
                        id: call.id,
                        content: "{\"status\":\"deferred\",\"detail\":\"Waiting for the "
                            + "user to respond to an earlier confirmation.\"}",
                        isError: false))
                    continue
                }

                switch executor.execute(call) {
                case .result(let json):
                    append(.toolActivity(Self.activityLabel(for: call.tool)))
                    resultBlocks.append(.toolResult(id: call.id, content: json, isError: false))

                case .failure(let message):
                    append(.error(message))
                    resultBlocks.append(.toolResult(
                        id: call.id,
                        content: "{\"status\":\"error\",\"detail\":\"\(Self.escape(message))\"}",
                        isError: true))

                case .awaitingConfirmation(let write):
                    pendingWrite = write
                    append(.proposal(write))
                    paused = true
                }
            }

            if paused {
                // Stash the results gathered so far; they are sent together with
                // the confirmation outcome.
                deferredResults = resultBlocks
                return
            }

            turns.append(AssistantTurn(role: .user, blocks: resultBlocks))
        }

        append(.error("The assistant kept requesting data without answering. "
                      + "Try rephrasing your question."))
    }

    // MARK: Confirmation gate

    /// The user accepted the proposed write. This is the only path that commits.
    func confirmPendingWrite() async {
        guard let write = pendingWrite else { return }
        pendingWrite = nil

        let resultJSON: String
        var summary: String
        do {
            resultJSON = try executor.commit(write)
            summary = Self.successSummary(for: write)
            Haptics.success()
        } catch {
            let message = error.localizedDescription
            append(.error(message))
            Haptics.error()
            resultJSON = "{\"status\":\"error\",\"detail\":\"\(Self.escape(message))\"}"
            summary = "Could not apply that change."
            append(.proposalResolved(summary: summary, confirmed: false))
            await resume(with: write, resultJSON: resultJSON, isError: true)
            return
        }

        append(.proposalResolved(summary: summary, confirmed: true))
        await resume(with: write, resultJSON: resultJSON, isError: false)
    }

    /// The user declined. Nothing is written, and the model is told so.
    func declinePendingWrite() async {
        guard let write = pendingWrite else { return }
        pendingWrite = nil
        Haptics.warning()

        append(.proposalResolved(summary: "Not saved.", confirmed: false))
        await resume(with: write,
                     resultJSON: executor.declinedResult(for: write),
                     isError: false)
    }

    private func resume(with write: PendingAssistantWrite,
                        resultJSON: String,
                        isError: Bool) async {
        var blocks = deferredResults
        deferredResults = []
        blocks.insert(.toolResult(id: write.id, content: resultJSON, isError: isError),
                      at: 0)
        turns.append(AssistantTurn(role: .user, blocks: blocks))
        await runLoop()
    }

    // MARK: Transcript helpers

    func clearConversation() {
        messages = []
        turns = []
        deferredResults = []
        pendingWrite = nil
    }

    private func append(_ kind: AssistantChatMessage.Kind) {
        messages.append(AssistantChatMessage(kind: kind))
    }

    private static func activityLabel(for tool: AssistantTool) -> String {
        switch tool {
        case .queryEntries: "Read your food log"
        case .getTrends: "Read your trends"
        default: tool.rawValue
        }
    }

    static func successSummary(for write: PendingAssistantWrite) -> String {
        switch write.action {
        case .add(let draft):
            "Added \(draft.name)."
        case .edit(_, let draft, _):
            "Updated \(draft.name)."
        case .delete(_, let name, _):
            "Deleted \(name)."
        }
    }

    /// Escapes a message for embedding in a hand-built JSON string.
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
