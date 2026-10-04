import Foundation
import SwiftData
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// A message as shown in the chat transcript.
struct AssistantChatMessage: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        /// Text may be empty when only a photo was sent.
        case user(text: String, images: [Data])
        case assistant(String)
        /// A write awaiting confirmation, rendered as a card.
        case proposal(PendingAssistantWrite)
        /// Resolution of a proposal, so the transcript keeps a record.
        case proposalResolved(summary: String, confirmed: Bool)
        case error(String)
        case toolActivity(String)
    }

    var id = UUID()
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
    /// The write currently awaiting confirmation. Only one card is open at a
    /// time, so the user is never asked to approve a batch they cannot inspect.
    private(set) var pendingWrite: PendingAssistantWrite?
    /// Cards closed because the user asked for changes and a new one replaced them.
    private(set) var replacedWriteIDs: Set<String> = []
    /// True once the model has been told the open card is still waiting, so its
    /// eventual outcome goes in `contextNotes` rather than as a tool result.
    private var pendingResultSent = false
    /// Outcomes to tell the model with the next message, without asking it to reply.
    private var contextNotes: [String] = []

    var composerText = ""
    /// Photos attached to the next message, in the order added. An attachment
    /// with no data yet is still loading and shows a spinner, as in Claude.
    private(set) var attachments: [ComposerAttachment] = []

    /// Caps upload size and token use; four covers a menu spread over pages.
    static let maxAttachments = 4

    var canAttachMore: Bool { attachments.count < Self.maxAttachments }
    var remainingAttachmentSlots: Int { max(0, Self.maxAttachments - attachments.count) }
    var isLoadingAttachment: Bool { attachments.contains { $0.data == nil } }

    /// Adds a loading placeholder straight away and returns its id; call
    /// `finishAttachment` once the photo is ready (or failed).
    func beginAttachment() -> UUID? {
        guard canAttachMore else { return nil }
        let attachment = ComposerAttachment()
        attachments.append(attachment)
        return attachment.id
    }

    /// Fills in a loading placeholder, or removes it if the photo couldn't be read.
    func finishAttachment(id: UUID, data: Data?) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        if let data {
            attachments[index].data = data
        } else {
            attachments.remove(at: index)
        }
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private var turns: [AssistantTurn] = []
    /// Tool results queued while a confirmation is outstanding.
    private var deferredResults: [AssistantTurn.Block] = []

    private let service: AssistantServing
    private let executor: AssistantToolExecutor
    private let contextBuilder: AssistantContextBuilder

    /// Guards against an unbounded tool loop if the model keeps calling tools.
    private static let maxToolRoundTrips = 5

    /// Sent to the model when the user attaches a photo without typing anything.
    static let photoOnlyPrompt = "What would you suggest from this, given what I have "
        + "left in my ranges today?"

    /// Runs an attached photo through the on-device models (A then B) and
    /// describes what they found, for the model to log from. Nil when the food
    /// recognition model isn't installed: the photo then goes to the LLM alone.
    typealias PhotoAnalyser = @MainActor (Data) async -> String?
    private let photoAnalyser: PhotoAnalyser?

    /// Where chats are saved; nil keeps them in memory only (tests, previews).
    private let historyStore: ChatHistoryStore?
    /// The chat on screen. Changes when starting a new chat or opening an old one.
    private(set) var conversationID = UUID()
    private var conversationCreatedAt = Date.now

    init(service: AssistantServing,
         executor: AssistantToolExecutor,
         contextBuilder: AssistantContextBuilder,
         photoAnalyser: PhotoAnalyser? = nil,
         historyStore: ChatHistoryStore? = nil) {
        self.service = service
        self.executor = executor
        self.contextBuilder = contextBuilder
        self.photoAnalyser = photoAnalyser
        self.historyStore = historyStore
    }

    /// The assistant uses the app's built-in key; there is nothing for the
    /// user to configure.
    @MainActor
    static func make(context: ModelContext) -> AssistantViewModel {
        let service: AssistantServing = BundledAPIKey.hasAssistantKey
            ? OpenAICompatibleAssistantService()
            : UnconfiguredAssistantService()

        let pipeline = PhotoAnalysisPipeline.make(context: context)
        // An if-statement rather than `cond ? { closure } : nil`: Swift can't
        // infer a closure's type through a ternary with an optional
        // @MainActor async function type ("type of expression is ambiguous").
        var analyser: PhotoAnalyser?
        if pipeline.canRecogniseFoods {
            analyser = { @MainActor (data: Data) async -> String? in
                await Self.describePhoto(data, using: pipeline)
            }
        }

        return AssistantViewModel(
            service: service,
            executor: AssistantToolExecutor(context: context),
            contextBuilder: AssistantContextBuilder(context: context),
            photoAnalyser: analyser,
            historyStore: .shared)
    }

    /// Plain-text summary of the on-device photo analysis: each food with its
    /// estimated grams and the calories the app calculated for it.
    @MainActor
    static func describePhoto(_ data: Data, using pipeline: PhotoAnalysisPipeline) async -> String? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data),
              let result = try? await pipeline.analyse(image: image, retainImage: false),
              !result.isEmpty else { return nil }

        var lines = ["On-device photo analysis (the app's own food recognition and "
                     + "portion models):"]
        for item in result.resolvedNutrition {
            let source = item.provenance.isEstimate ? "estimate" : item.provenance.displayName
            lines.append("- \(item.displayName): \(AppFormatters.amount(item.grams)) g, "
                         + "\(AppFormatters.amount(item.total.calories)) kcal (\(source))")
        }
        let total = result.resolvedNutrition.reduce(Nutrition.zero) { $0 + $1.total }
        lines.append("Total about \(AppFormatters.amount(total.calories)) kcal. "
                     + (result.portionsEstimated
                        ? "Portions are estimates from one photo."
                        : "Portion sizes are defaults; ask the user to confirm them."))
        return lines.joined(separator: "\n")
        #else
        return nil
        #endif
    }

    // MARK: Availability

    /// Ready, or unavailable because this build has no assistant key.
    var isAvailable: Bool { service.isConfigured }

    var canSend: Bool {
        isAvailable
            && !isSending
            && !isLoadingAttachment
            && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    // MARK: Sending

    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments.compactMap(\.data)
        guard !text.isEmpty || !images.isEmpty, !isLoadingAttachment else { return }

        guard isAvailable else {
            append(.error(AssistantServiceError.notConfigured.localizedDescription))
            return
        }

        composerText = ""
        attachments = []

        // Show the message straight away; the photo analysis below can take a moment.
        append(.user(text: text, images: images))

        // A card left open gets its "still waiting" result first, then any
        // outcomes the model hasn't heard about go in front of the message.
        notePendingCardBeforeNewMessage()
        var blocks: [AssistantTurn.Block] = contextNotes.map { .text("[Note: \($0)]") }
        contextNotes = []
        if !images.isEmpty, photoAnalyser != nil { isSending = true }
        for (index, image) in images.enumerated() {
            blocks.append(.image(image))
            // With the food models installed, the app's own recognition and
            // portion estimate go along with each photo, so logging uses those
            // grams and the app's nutrition data rather than an LLM's guess.
            if let photoAnalyser, let analysis = await photoAnalyser(image) {
                let label = images.count > 1 ? "Photo \(index + 1) of \(images.count). " : ""
                blocks.append(.text(label + analysis))
            }
        }
        // Photos sent on their own still need a question for the model; the
        // chat shows just the photos, as Claude and ChatGPT do.
        blocks.append(.text(text.isEmpty ? Self.photoOnlyPrompt : text))
        turns.append(AssistantTurn(role: .user, blocks: blocks))

        await runLoop()
        persist()
    }

    /// Sends the conversation and processes tool calls until the model stops
    /// calling tools or proposes a write.
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

            // Record the whole assistant turn - its text as well as its tool
            // calls - so the next request carries the full conversation.
            var assistantBlocks: [AssistantTurn.Block] = []
            if let text = response.text { assistantBlocks.append(.text(text)) }
            assistantBlocks += response.toolCalls.map {
                .toolUse(id: $0.id, name: $0.tool.rawValue, input: $0.arguments, extra: $0.extra)
            }
            if !assistantBlocks.isEmpty {
                turns.append(AssistantTurn(role: .assistant, blocks: assistantBlocks))
            }

            // A turn that proposes an entry shows only the card: the card is
            // the reply, so any text alongside it is not displayed.
            let proposesWrite = response.toolCalls.contains { $0.tool.isWrite }
            if let text = response.text, !proposesWrite {
                append(.assistant(text))
            }

            guard response.hasToolCalls else { return }

            var resultBlocks: [AssistantTurn.Block] = []
            var paused = false

            for call in response.toolCalls {
                if paused {
                    // Anything after a proposal waits: the provider needs a
                    // result for every tool call, and these can't be answered
                    // until the user has decided.
                    resultBlocks.append(.toolResult(
                        id: call.id,
                        content: "{\"status\":\"deferred\",\"detail\":\"Waiting for the "
                            + "user to respond to the confirmation card.\"}",
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
                    // A new proposal while a card is still open is the amended
                    // version: the old card closes as replaced.
                    if let previous = pendingWrite {
                        replacedWriteIDs.insert(previous.id)
                    }
                    pendingWrite = write
                    pendingResultSent = false
                    append(.proposal(write))
                    paused = true
                }
            }

            if paused {
                // Held until the user acts on the card, or sends another message.
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
    ///
    /// No follow-up request is made: the card already shows what was saved, so
    /// the assistant doesn't reply. The outcome is recorded in the history so
    /// the model knows about it next time the user writes.
    func confirmPendingWrite() async {
        guard let write = pendingWrite else { return }

        do {
            let resultJSON = try executor.commit(write)
            Haptics.success()
            append(.proposalResolved(summary: Self.successSummary(for: write), confirmed: true))
            record(write, resultJSON: resultJSON, isError: false,
                   note: "The user confirmed the card: \(resultJSON)")
        } catch {
            let message = error.localizedDescription
            Haptics.error()
            append(.error(message))
            append(.proposalResolved(summary: "Could not apply that change.", confirmed: false))
            record(write, resultJSON: "{\"status\":\"error\",\"detail\":\"\(Self.escape(message))\"}",
                   isError: true,
                   note: "Saving the card failed: \(message)")
        }
    }

    /// The user declined. Nothing is written, and no reply is requested.
    func declinePendingWrite() async {
        guard let write = pendingWrite else { return }
        Haptics.warning()
        append(.proposalResolved(summary: "Not saved.", confirmed: false))
        record(write, resultJSON: executor.declinedResult(for: write), isError: false,
               note: "The user cancelled the card; nothing was saved.")
    }

    /// Closes the open card and records its outcome without calling the model.
    private func record(_ write: PendingAssistantWrite, resultJSON: String,
                        isError: Bool, note: String) {
        if pendingResultSent {
            // The model was already told the card was waiting (the user kept
            // chatting), so the outcome rides along with the next message.
            contextNotes.append(note)
        } else {
            var blocks = deferredResults
            blocks.insert(.toolResult(id: write.id, content: resultJSON, isError: isError), at: 0)
            turns.append(AssistantTurn(role: .user, blocks: blocks))
        }
        deferredResults = []
        pendingWrite = nil
        pendingResultSent = false
        persist()
    }

    /// Called when the user sends a message while a card is still open. The
    /// card stays open, but the model must be told it is waiting - every tool
    /// call needs a result before the conversation can continue. Telling it
    /// what the card holds lets it amend the card if the user asks.
    private func notePendingCardBeforeNewMessage() {
        guard let write = pendingWrite, !pendingResultSent else { return }
        var blocks = deferredResults
        blocks.insert(.toolResult(id: write.id,
                                  content: Self.awaitingResult(for: write),
                                  isError: false), at: 0)
        turns.append(AssistantTurn(role: .user, blocks: blocks))
        deferredResults = []
        pendingResultSent = true
    }

    static func awaitingResult(for write: PendingAssistantWrite) -> String {
        let card: String = switch write.action {
        case .add(let draft):
            "Add \(draft.name): "
                + (draft.isComposite
                   ? draft.ingredients.map { "\($0.name) \(AppFormatters.amount($0.quantity)) g" }
                       .joined(separator: ", ")
                   : "\(AppFormatters.amount(draft.quantity)) \(draft.unit.shortLabel)")
                + ", \(AppFormatters.amount(draft.total.calories)) kcal"
        case .edit(_, let draft, _):
            "Update \(draft.name)"
        case .delete(_, let name, _):
            "Delete \(name)"
        }
        return "{\"status\":\"awaiting_user\",\"card\":\"\(escape(card))\",\"detail\":\"Shown to "
            + "the user as a confirmation card, not yet confirmed or cancelled. If the user "
            + "now asks to change it, propose the complete amended version and it will "
            + "replace this card. Otherwise answer them and leave the card as it is.\"}"
    }

    // MARK: Chat history

    /// Saves the chat on screen, once it has at least one message from the user.
    func persist() {
        guard let historyStore,
              messages.contains(where: { if case .user = $0.kind { return true }; return false })
        else { return }
        historyStore.save(SavedConversation(id: conversationID,
                                            title: SavedConversation.title(for: messages),
                                            createdAt: conversationCreatedAt,
                                            updatedAt: .now,
                                            messages: messages,
                                            turns: turns))
    }

    /// Saves the current chat and starts an empty one.
    func startNewConversation() {
        persist()
        resetState()
        conversationID = UUID()
        conversationCreatedAt = .now
    }

    /// Reopens a saved chat so the user can read it or carry on.
    func open(_ conversation: SavedConversation) {
        guard conversation.id != conversationID else { return }
        persist()
        resetState()
        conversationID = conversation.id
        conversationCreatedAt = conversation.createdAt
        messages = conversation.messages
        turns = Self.closingUnansweredToolCalls(in: conversation.turns)
    }

    /// A chat saved while a card was still open has a tool call with no
    /// result, which the provider would reject. The card can't be acted on
    /// any more (nothing is open after reopening), so it is recorded as closed.
    static func closingUnansweredToolCalls(in turns: [AssistantTurn]) -> [AssistantTurn] {
        let blocks = turns.flatMap(\.blocks)
        let answered = Set(blocks.compactMap { block -> String? in
            if case .toolResult(let id, _, _) = block { return id }
            return nil
        })
        let unanswered = blocks.compactMap { block -> String? in
            if case .toolUse(let id, _, _, _) = block, !answered.contains(id) { return id }
            return nil
        }
        guard !unanswered.isEmpty else { return turns }
        let closed = unanswered.map { id in
            AssistantTurn.Block.toolResult(
                id: id,
                content: "{\"status\":\"closed\",\"detail\":\"The chat was closed and reopened "
                    + "before the user decided. Nothing was saved.\"}",
                isError: false)
        }
        return turns + [AssistantTurn(role: .user, blocks: closed)]
    }

    private func resetState() {
        messages = []
        turns = []
        deferredResults = []
        pendingWrite = nil
        pendingResultSent = false
        contextNotes = []
        replacedWriteIDs = []
        attachments = []
        composerText = ""
    }

    // MARK: Transcript helpers

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

/// One photo in the composer. `data` is nil while it is still being loaded
/// and downsized, which the composer shows as a spinner.
struct ComposerAttachment: Identifiable, Equatable {
    let id = UUID()
    var data: Data?
}
