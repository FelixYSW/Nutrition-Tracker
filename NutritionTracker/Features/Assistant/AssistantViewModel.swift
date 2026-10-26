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
        /// Names of the files sent with the next user message.
        case userFiles([String])
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
/// One conversation's state: what the user sees, what the model is sent, and
/// any open cards.
///
/// Each chat has its own, so a reply still on its way keeps writing to the
/// chat it was asked in even after the user opens another one - before, all
/// chats shared one set of state and a late reply landed in whichever chat
/// was on screen.
@MainActor
@Observable
final class ChatSession {
    let id: UUID
    let createdAt: Date

    var messages: [AssistantChatMessage] = []
    var isSending = false
    var pendingWrites: [PendingAssistantWrite] = []
    var replacedWriteIDs: Set<String> = []
    var unansweredCardIDs: [String] = []
    var contextNotes: [String] = []
    var turns: [AssistantTurn] = []
    var deferredResults: [AssistantTurn.Block] = []
    var cardOutcomes: [String: [String]] = [:]
    var lookedUpProducts: [String] = []

    init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }

    /// Kept in memory when the user switches away: a reply is on its way, or
    /// cards are waiting for an answer.
    var needsKeeping: Bool { isSending || !pendingWrites.isEmpty }
}

@MainActor
@Observable
final class AssistantViewModel {

    /// The chat on screen.
    private(set) var session = ChatSession()
    /// Chats switched away from that are still working or have open cards,
    /// by id, so opening them again shows them live, not a saved copy.
    private var keptSessions: [UUID: ChatSession] = [:]

    var messages: [AssistantChatMessage] { session.messages }
    var isSending: Bool { session.isSending }

    /// The reply currently appearing word by word, and how many characters of
    /// it are showing. The message itself always holds the whole reply, so
    /// saving and the model's history never see a partial one.
    private(set) var revealingMessageID: UUID?
    private(set) var revealedLength = 0
    private var revealTask: Task<Void, Never>?
    /// Cards awaiting confirmation, in the order shown. A meal of several
    /// dishes (miso soup, chawanmushi, salmon don) gets one card per dish, so
    /// each can be confirmed, cancelled or changed on its own.
    var pendingWrites: [PendingAssistantWrite] { session.pendingWrites }
    /// The first open card, for callers that deal with one at a time.
    var pendingWrite: PendingAssistantWrite? { pendingWrites.first }
    /// Cards closed because the user asked for changes and a new one replaced them.
    var replacedWriteIDs: Set<String> { session.replacedWriteIDs }
    /// Open cards from the latest model turn that still owe it a tool result.
    /// Once a card's "still waiting" result has gone out (the user kept
    /// chatting), its eventual outcome goes in `contextNotes` instead.
    private var unansweredCardIDs: [String] {
        get { session.unansweredCardIDs }
        set { session.unansweredCardIDs = newValue }
    }
    /// Outcomes to tell the model with the next message, without asking it to reply.
    private var contextNotes: [String] {
        get { session.contextNotes }
        set { session.contextNotes = newValue }
    }

    var composerText = ""
    /// Photos attached to the next message, in the order added. An attachment
    /// with no data yet is still loading and shows a spinner, as in Claude.
    private(set) var attachments: [ComposerAttachment] = []

    /// Photos and files together. Caps upload size and token use; the app's
    /// own limit, not the provider's (OpenAI takes far more images per request).
    static let maxAttachments = 10
    /// Per file. Photos are downsized, so only files need a size cap.
    static let maxFileBytes = 10_000_000
    /// Kinds the composer accepts besides photos.
    static let fileExtensions: Set<String> = ["pdf", "txt", "csv", "md", "json"]

    var canAttachMore: Bool { attachments.count < Self.maxAttachments }
    var remainingAttachmentSlots: Int { max(0, Self.maxAttachments - attachments.count) }
    var isLoadingAttachment: Bool { attachments.contains { $0.data == nil } }

    /// Adds a loading placeholder straight away and returns its id; call
    /// `finishAttachment` once the photo is ready (or failed).
    func beginAttachment(fileName: String? = nil) -> UUID? {
        guard canAttachMore else { return nil }
        let attachment = ComposerAttachment(fileName: fileName)
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

    private var turns: [AssistantTurn] {
        get { session.turns }
        set { session.turns = newValue }
    }
    /// Tool results for the latest model turn, held until every card in it has
    /// an answer (or the user sends another message).
    private var deferredResults: [AssistantTurn.Block] {
        get { session.deferredResults }
        set { session.deferredResults = newValue }
    }
    /// Outcomes of cards whose call made several cards, until all are answered.
    private var cardOutcomes: [String: [String]] {
        get { session.cardOutcomes }
        set { session.cardOutcomes = newValue }
    }

    private let service: AssistantServing
    private let executor: AssistantToolExecutor
    private let contextBuilder: AssistantContextBuilder

    /// Guards against an unbounded tool loop if the model keeps calling tools.
    private static let maxToolRoundTrips = 5

    /// Sent to the model when the user attaches a file without typing anything.
    static let fileOnlyPrompt = "[The user sent only this file, with no message. Read it; "
        + "if it is a check-up or lab report, follow section 17.]"

    /// Sent to the model when the user attaches a photo without typing anything.
    static let photoOnlyPrompt = "[The user sent only this photo, with no message. Follow "
        + "the rules for a photo on its own.]"

    /// Runs an attached photo through the on-device models (A then B) and
    /// describes what they found, for the model to log from. Nil when the food
    /// recognition model isn't installed: the photo then goes to the LLM alone.
    typealias PhotoAnalyser = @MainActor (Data) async -> String?
    private let photoAnalyser: PhotoAnalyser?

    /// Where chats are saved; nil keeps them in memory only (tests, previews).
    private let historyStore: ChatHistoryStore?
    /// Finds where the user is, for food nearby when they don't name a place.
    private let locator: CurrentLocating?
    /// The chat on screen. Changes when starting a new chat or opening an old one.
    var conversationID: UUID { session.id }

    init(service: AssistantServing,
         executor: AssistantToolExecutor,
         contextBuilder: AssistantContextBuilder,
         photoAnalyser: PhotoAnalyser? = nil,
         historyStore: ChatHistoryStore? = nil,
         locator: CurrentLocating? = nil) {
        self.locator = locator
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
            ? OpenAIAssistantService()
            : UnconfiguredAssistantService()

        // Photos go straight to the assistant's model: the app no longer runs
        // its own food recognition models on them.
        return AssistantViewModel(
            service: service,
            executor: AssistantToolExecutor(context: context),
            contextBuilder: AssistantContextBuilder(context: context),
            historyStore: .shared,
            locator: CurrentLocationProvider())
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
        let images = attachments.filter { $0.fileName == nil }.compactMap(\.data)
        let files = attachments.compactMap { attachment -> (name: String, data: Data)? in
            guard let name = attachment.fileName, let data = attachment.data else { return nil }
            return (name, data)
        }
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty, !isLoadingAttachment else { return }

        guard isAvailable else {
            append(.error(AssistantServiceError.notConfigured.localizedDescription))
            return
        }

        composerText = ""
        attachments = []
        finishReveal()

        // The chat this message belongs to. Everything below writes to it,
        // even if the user opens another chat before the reply arrives.
        let chat = session

        // Show the message straight away, and save it so it's in Past chats
        // even while the reply is still on its way.
        if !files.isEmpty { append(.userFiles(files.map(\.name)), to: chat) }
        if !text.isEmpty || !images.isEmpty { append(.user(text: text, images: images), to: chat) }
        persist(chat)

        // A card left open gets its "still waiting" result first, then any
        // outcomes the model hasn't heard about go in front of the message.
        notePendingCardBeforeNewMessage()
        var blocks: [AssistantTurn.Block] = chat.contextNotes.map { .text("[Note: \($0)]") }
        chat.contextNotes = []
        if !images.isEmpty, photoAnalyser != nil { chat.isSending = true }
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
        for file in files { blocks.append(.file(name: file.name, data: file.data)) }
        // Photos or files sent on their own still need a question for the
        // model; the chat shows just the attachments, as Claude and ChatGPT do.
        let attachmentOnlyPrompt = files.isEmpty ? Self.photoOnlyPrompt : Self.fileOnlyPrompt
        blocks.append(.text(text.isEmpty ? attachmentOnlyPrompt : text))
        chat.turns.append(AssistantTurn(role: .user, blocks: blocks))

        await runLoop(in: chat)
        persist(chat)
        // Finished in the background with nothing left open: no need to keep
        // it in memory - opening it again loads the saved copy.
        if chat !== session, !chat.needsKeeping {
            keptSessions[chat.id] = nil
        }
    }

    /// Sends the conversation and processes tool calls until the model stops
    /// calling tools or proposes a write. Works on `chat` throughout, which
    /// may no longer be the chat on screen by the time a reply arrives.
    private func runLoop(in chat: ChatSession) async {
        chat.isSending = true
        defer { chat.isSending = false }

        for _ in 0..<Self.maxToolRoundTrips {
            let contextJSON: String
            do {
                contextJSON = try contextBuilder.encodedJSON()
            } catch {
                append(.error("Could not assemble your nutrition context."), to: chat)
                return
            }

            let response: AssistantResponse
            do {
                response = try await service.send(turns: chat.turns,
                                                   contextJSON: contextJSON,
                                                   tools: AssistantTool.allCases)
            } catch let error as AssistantServiceError {
                append(.error(error.localizedDescription), to: chat)
                return
            } catch {
                append(.error(error.localizedDescription), to: chat)
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
                chat.turns.append(AssistantTurn(role: .assistant, blocks: assistantBlocks))
            }

            // A turn that proposes a food entry shows only the card: the card
            // is the reply, so any text alongside it is not displayed. Profile,
            // range and health-note cards keep their text - reading a check-up
            // report, the explanation is the point.
            let foodWrites: Set<AssistantTool> = [.addFoodEntry, .repeatFoodEntry,
                                                  .editFoodEntry, .deleteFoodEntry]
            let proposesWrite = response.toolCalls.contains { foodWrites.contains($0.tool) }
            if let text = response.text, !proposesWrite {
                append(.assistant(text), to: chat)
                // Word by word only when the user is looking at this chat.
                if chat === session, let id = chat.messages.last?.id { reveal(id, text: text) }
            }

            guard response.hasToolCalls else { return }

            var resultBlocks: [AssistantTurn.Block] = []
            var proposals: [PendingAssistantWrite] = []
            var replacing: [String: String] = [:]   // new card id -> card it replaces
            var keepsTime: Set<String> = []         // new cards sent without a time

            // One note per reply is enough when several searches fail alike.
            var shownSearchFailure = false
            for call in response.toolCalls {
                // Web search goes out over the network, so it runs here rather
                // than in the executor, which only reads the local database.
                if call.tool.usesWebSearch {
                    // Food nearby with no place named searches around the
                    // user's current location instead of guessing a place.
                    var here: CurrentPlace?
                    if call.tool == .findFoodNearby, Self.namedPlace(in: call.arguments) == nil {
                        do {
                            guard let locator else { throw CurrentLocationError.unavailable }
                            here = try await locator.currentPlace()
                        } catch {
                            resultBlocks.append(.toolResult(
                                id: call.id,
                                content: "{\"status\":\"error\",\"detail\":\""
                                    + Self.escape(error.localizedDescription
                                                  + " Ask the user which area they're in.") + "\"}",
                                isError: true))
                            continue
                        }
                    }
                    let (question, activity) = Self.webQuestion(for: call, currentPlace: here)
                    append(.toolActivity(activity), to: chat)
                    let (content, failed, summary, failure) = await searchWeb(question)
                    // The model only says "the lookup failed"; the reason (wrong
                    // model name, no quota) is for the user to see.
                    if let failure, !shownSearchFailure {
                        shownSearchFailure = true
                        append(.error("Search failed: \(failure)"), to: chat)
                    }
                    // Only a lookup that actually found published figures
                    // holds the product to them; "nothing found" doesn't.
                    if call.tool == .lookUpProductNutrition, !failed,
                       let summary, Self.foundPublishedFigures(in: summary),
                       let product = call.arguments["product"]?.stringValue {
                        chat.lookedUpProducts.append(product)
                    }
                    resultBlocks.append(.toolResult(id: call.id, content: content, isError: failed))
                    continue
                }

                // A product that was just looked up must be logged with its
                // published figures, not a guess. Enforced once per product:
                // if the model sends an estimate again, the lookup evidently
                // had nothing usable, and refusing again would leave the user
                // unable to log the food at all.
                if [.addFoodEntry, .editFoodEntry, .calculateNutrition].contains(call.tool),
                   let detail = Self.unusedBrandFigures(in: call.arguments,
                                                        lookedUp: chat.lookedUpProducts) {
                    let blocked = Set(Self.productsSentAsEstimates(in: call.arguments,
                                                                   lookedUp: chat.lookedUpProducts))
                    chat.lookedUpProducts.removeAll { blocked.contains($0) }
                    resultBlocks.append(.toolResult(id: call.id, content: detail, isError: true))
                    continue
                }

                // An edit or delete aimed at a card that hasn't been saved yet
                // uses the card's id, which is not an entry. Steer the model
                // to amend the card instead of failing.
                if call.tool == .editFoodEntry || call.tool == .deleteFoodEntry,
                   let target = call.arguments["id"]?.stringValue,
                   let card = chat.pendingWrites.first(where: { $0.id == target }) {
                    resultBlocks.append(.toolResult(
                        id: call.id,
                        content: Self.unsavedCardResult(for: card, tool: call.tool),
                        isError: true))
                    continue
                }

                switch executor.execute(call) {
                case .result(let json):
                    append(.toolActivity(Self.activityLabel(for: call.tool)), to: chat)
                    resultBlocks.append(.toolResult(id: call.id, content: json, isError: false))

                case .failure(let message):
                    // Told to the model, which corrects itself (wrong id,
                    // missing figures, misread label) or explains in its reply.
                    // Not shown in the chat: it's the assistant's mistake to fix.
                    resultBlocks.append(.toolResult(
                        id: call.id,
                        content: "{\"status\":\"error\",\"detail\":\"\(Self.escape(message))\"}",
                        isError: true))

                case .awaitingConfirmation(let write):
                    proposals.append(write)
                    let food = AssistantToolExecutor.foods(in: call.arguments).first ?? call.arguments
                    if let target = food["replacesCard"]?.stringValue {
                        replacing[write.id] = target
                    }
                    if food["consumedAt"] == nil { keepsTime.insert(write.id) }

                case .awaitingConfirmations(let writes):
                    // One card per food; each food may name a card it amends.
                    let foods = AssistantToolExecutor.foods(in: call.arguments)
                    for (write, food) in zip(writes, foods) {
                        proposals.append(write)
                        if let target = food["replacesCard"]?.stringValue {
                            replacing[write.id] = target
                        }
                        if food["consumedAt"] == nil { keepsTime.insert(write.id) }
                    }
                }
            }

            if !proposals.isEmpty {
                openCards(proposals, replacing: replacing, keepsTime: keepsTime, in: chat)
                // Held until the user answers every card, or sends another message.
                chat.deferredResults = resultBlocks
                chat.unansweredCardIDs = proposals.map(\.id)
                return
            }

            chat.turns.append(AssistantTurn(role: .user, blocks: resultBlocks))
        }

        append(.error("The assistant kept requesting data without answering. "
                      + "Try rephrasing your question."), to: chat)
    }

    // MARK: Web search

    /// The search question for a web tool, and the activity line shown in the chat.
    /// The area the user named for food nearby, or nil to use where they are.
    /// "Near me" and the like count as not naming one.
    static func namedPlace(in arguments: [String: JSONValue]) -> String? {
        guard let place = arguments["place"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else { return nil }
        let meaningHere = ["near me", "nearby", "here", "around me", "current location",
                           "my location", "my current location", "where i am"]
        return meaningHere.contains(place.lowercased()) ? nil : place
    }

    static func webQuestion(for call: AssistantToolCall,
                            currentPlace: CurrentPlace? = nil) -> (question: String, activity: String) {
        let arguments = call.arguments
        if call.tool == .findProducts {
            let query = arguments["query"]?.stringValue ?? ""
            return (productSearchQuestion(query: query,
                                          country: arguments["country"]?.stringValue,
                                          goal: arguments["goal"]?.stringValue),
                    "Searched for \(query)")
        }
        if call.tool == .lookUpProductNutrition {
            let product = arguments["product"]?.stringValue ?? ""
            return (productNutritionQuestion(product: product,
                                             country: arguments["country"]?.stringValue),
                    "Looked up nutrition for \(product)")
        }
        // Places to eat around the user, with menu items and prices, for the
        // model to fit to the user's ranges and budget.
        let budget = arguments["budget"]?.stringValue
        let preferences = arguments["preferences"]?.stringValue
        if let currentPlace, namedPlace(in: arguments) == nil {
            return (nearbyFoodQuestion(place: currentPlace.searchDescription, budget: budget,
                                       preferences: preferences, isCurrentLocation: true),
                    "Searched for food near you" + (currentPlace.name.map { " (\($0))" } ?? ""))
        }
        let place = namedPlace(in: arguments) ?? ""
        return (nearbyFoodQuestion(place: place, budget: budget, preferences: preferences),
                "Searched for food near \(place)")
    }

    static func productSearchQuestion(query: String, country: String?, goal: String?) -> String {
        var lines = [
            "Find real products currently sold\(country.map { " in \($0)" } ?? ""): \(query).",
            "List up to 6, each with the exact brand and product name as on the pack, and "
                + "its published nutrition per serving and per 100 g: kcal, protein, carbs, fat.",
            "Only include products you found on the manufacturer's site, a retailer or the "
                + "label. Never invent a product or its figures; say if you found fewer."
        ]
        if let goal = goal?.trimmingCharacters(in: .whitespaces), !goal.isEmpty {
            lines.append("Rank them by: \(goal).")
        }
        return lines.joined(separator: "\n")
    }

    static func productNutritionQuestion(product: String, country: String?) -> String {
        var lines = [
            "Find the official nutrition facts for \(product).",
            "Give per 100 g (or per 100 ml for drinks): energy in kcal, protein, carbohydrate, "
                + "total fat and dietary fibre in grams. If the label only gives per serving, "
                + "give the serving size too and convert to per 100 g.",
            "Also give the usual serving or pack size (e.g. one cup, one bottle in ml).",
            "Prefer the manufacturer's website or the product's label. Name the exact product "
                + "variant the figures are for.",
            "If no published nutrition figures exist for this product, start your answer with "
                + "NOT FOUND and do not make up or estimate any numbers."
        ]
        if let country = country?.trimmingCharacters(in: .whitespaces), !country.isEmpty {
            lines.append("The product as sold in \(country).")
        }
        return lines.joined(separator: "\n")
    }

    /// The tool result, whether it failed, the answer text when it didn't, and
    /// the reason when it did.
    private func searchWeb(_ question: String) async -> (String, Bool, String?, String?) {
        do {
            let result = try await service.searchWeb(question)
            struct Payload: Encodable {
                let status = "ok"
                let summary: String
                let sources: [WebSearchResult.Source]
            }
            let data = try JSONEncoder().encode(Payload(summary: result.summary, sources: result.sources))
            return (String(decoding: data, as: UTF8.self), false, result.summary, nil)
        } catch {
            return ("{\"status\":\"error\",\"detail\":\"\(Self.escape(error.localizedDescription))\"}",
                    true, nil, error.localizedDescription)
        }
    }

    /// Whether a nutrition lookup's answer has real published figures: it
    /// doesn't open with NOT FOUND, and it gives at least one calorie number.
    static func foundPublishedFigures(in summary: String) -> Bool {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("NOT FOUND") { return false }
        let calorieNumber = #"\d[\d.,]*\s*(kcal|calories|cal\b)"#
        return text.range(of: calorieNumber, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func nearbyFoodQuestion(place: String, budget: String?, preferences: String?,
                                   isCurrentLocation: Bool = false) -> String {
        let whereText = isCurrentLocation
            ? "within about 1.5 km (a short walk or drive) of the user's current location: "
                + "\(place). Nearest first"
            : "at or right next to \(place)"
        var lines = [
            "Find restaurants, food court stalls, cafes and kiosks that are open and operating "
                + "\(whereText). List up to 8 that suit the request.",
            "For each: the name, where it is (floor, wing or street) if known, the cuisine, "
                + "and 2 to 4 specific menu items with their current prices in local currency "
                + "and a short portion description.",
            "Only include real places and dishes you found; say if prices may be out of date."
        ]
        if let budget = budget?.trimmingCharacters(in: .whitespaces), !budget.isEmpty {
            lines.append("Budget: \(budget). Only include items that fit it.")
        }
        if let preferences = preferences?.trimmingCharacters(in: .whitespaces), !preferences.isEmpty {
            lines.append("Prefer: \(preferences).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Confirmation gate

    /// The user accepted the proposed write. This is the only path that commits.
    ///
    /// No follow-up request is made: the card already shows what was saved, so
    /// the assistant doesn't reply. The outcome is recorded in the history so
    /// the model knows about it next time the user writes.
    func confirm(_ write: PendingAssistantWrite) async {
        guard pendingWrites.contains(where: { $0.id == write.id }) else { return }

        do {
            let resultJSON = try executor.commit(write)
            Haptics.success()
            append(.proposalResolved(summary: Self.successSummary(for: write), confirmed: true))
            record(write, resultJSON: resultJSON, isError: false,
                   note: "The user confirmed the card for \(Self.cardTitle(for: write)): \(resultJSON)")
        } catch {
            let message = error.localizedDescription
            Haptics.error()
            append(.error(message))
            append(.proposalResolved(summary: "Could not apply that change.", confirmed: false))
            record(write, resultJSON: "{\"status\":\"error\",\"detail\":\"\(Self.escape(message))\"}",
                   isError: true,
                   note: "Saving the card for \(Self.cardTitle(for: write)) failed: \(message)")
        }
    }

    /// The user declined. Nothing is written, and no reply is requested.
    func decline(_ write: PendingAssistantWrite) async {
        guard pendingWrites.contains(where: { $0.id == write.id }) else { return }
        Haptics.warning()
        append(.proposalResolved(summary: "\(Self.cardTitle(for: write)) not saved.", confirmed: false))
        record(write, resultJSON: executor.declinedResult(for: write), isError: false,
               note: "The user cancelled the card for \(Self.cardTitle(for: write)); "
                   + "nothing was saved.")
    }

    /// "Add all" for a meal split into several cards. Only additions: edits
    /// and deletions are always confirmed one by one.
    var confirmableTogether: [PendingAssistantWrite] {
        pendingWrites.filter { if case .add = $0.action { return true }; return false }
    }

    func confirmAllAdditions() async {
        for write in confirmableTogether { await confirm(write) }
    }

    /// Confirms or cancels the first open card.
    func confirmPendingWrite() async {
        if let write = pendingWrite { await confirm(write) }
    }

    func declinePendingWrite() async {
        if let write = pendingWrite { await decline(write) }
    }

    /// Shows the new cards. A card the model says it amends - or one with the
    /// same name - closes as replaced; all others stay open alongside.
    ///
    /// An amended card sent without a time keeps the time of the card it
    /// replaces: correcting the brand of last night's shake mustn't move it
    /// to now.
    private func openCards(_ proposals: [PendingAssistantWrite], replacing: [String: String],
                           keepsTime: Set<String> = [], in chat: ChatSession) {
        for proposal in proposals {
            var write = proposal
            let target = replacing[write.id] ?? chat.pendingWrites.first {
                Self.cardTitle(for: $0).caseInsensitiveCompare(Self.cardTitle(for: write)) == .orderedSame
            }?.id
            if let target, let index = chat.pendingWrites.firstIndex(where: { $0.id == target }) {
                if keepsTime.contains(write.id) {
                    write = Self.retimed(write, like: chat.pendingWrites[index])
                }
                chat.replacedWriteIDs.insert(target)
                chat.pendingWrites.remove(at: index)
            }
            chat.pendingWrites.append(write)
            append(.proposal(write), to: chat)
        }
    }

    /// The write with its time taken from another card.
    static func retimed(_ write: PendingAssistantWrite,
                        like other: PendingAssistantWrite) -> PendingAssistantWrite {
        guard case .add(var draft) = write.action else { return write }
        let time: Date? = switch other.action {
        case .add(let old), .edit(_, let old, _): old.consumedAt
        case .delete, .profile, .ranges, .healthNotes: nil
        }
        guard let time else { return write }
        draft.consumedAt = time
        return PendingAssistantWrite(id: write.id, tool: write.tool, action: .add(draft))
    }

    /// Closes one card and records its outcome without calling the model.
    private func record(_ write: PendingAssistantWrite, resultJSON: String,
                        isError: Bool, note: String) {
        session.pendingWrites.removeAll { $0.id == write.id }
        if let index = unansweredCardIDs.firstIndex(of: write.id) {
            unansweredCardIDs.remove(at: index)
            let call = Self.callID(ofCard: write.id)
            cardOutcomes[call, default: []].append(resultJSON)
            // A call that made several cards gets one result, once all its
            // cards are answered.
            if !unansweredCardIDs.contains(where: { Self.callID(ofCard: $0) == call }) {
                let parts = cardOutcomes.removeValue(forKey: call) ?? []
                deferredResults.append(.toolResult(id: call, content: Self.combined(parts),
                                                   isError: isError && parts.count == 1))
            }
            if unansweredCardIDs.isEmpty { flushDeferredResults() }
        } else {
            // The model was already told the card was waiting (the user kept
            // chatting), so the outcome rides along with the next message.
            contextNotes.append(note)
        }
        persist()
    }

    private func flushDeferredResults() {
        if !deferredResults.isEmpty {
            turns.append(AssistantTurn(role: .user, blocks: deferredResults))
        }
        deferredResults = []
    }

    /// Called when the user sends a message while cards are still open. They
    /// stay open, but the model must be told they are waiting - every tool
    /// call needs a result before the conversation can continue. Telling it
    /// what each card holds lets it amend one if the user asks.
    private func notePendingCardBeforeNewMessage() {
        guard !unansweredCardIDs.isEmpty else { return }
        var callOrder: [String] = []
        for id in unansweredCardIDs {
            guard let write = pendingWrites.first(where: { $0.id == id }) else { continue }
            let call = Self.callID(ofCard: id)
            if !callOrder.contains(call) { callOrder.append(call) }
            cardOutcomes[call, default: []].append(Self.awaitingResult(for: write))
        }
        for call in callOrder {
            let parts = cardOutcomes.removeValue(forKey: call) ?? []
            deferredResults.append(.toolResult(id: call, content: Self.combined(parts),
                                               isError: false))
        }
        unansweredCardIDs = []
        flushDeferredResults()
    }

    /// Cards made from one call are "<call id>#1", "#2", ...; the model's
    /// tool call is the part before the "#".
    static func callID(ofCard cardID: String) -> String {
        cardID.split(separator: "#", maxSplits: 1).first.map(String.init) ?? cardID
    }

    /// One tool result for a call: a single card's JSON, or an array of them.
    static func combined(_ parts: [String]) -> String {
        parts.count == 1 ? parts[0] : "[" + parts.joined(separator: ",") + "]"
    }

    /// An error result when an item matches a looked-up product but was sent
    /// as an estimate, or nil when all is well.
    static func unusedBrandFigures(in arguments: [String: JSONValue],
                                   lookedUp products: [String]) -> String? {
        let unused = estimatedItems(in: arguments, lookedUp: products)
            .map { "\($0.name) (looked up as \($0.product))" }
        guard !unused.isEmpty else { return nil }
        return "{\"status\":\"error\",\"detail\":\"" + escape(
            "Nothing was logged. You looked up the published nutrition for "
                + unused.joined(separator: ", ") + " but sent an estimate. Send it again "
                + "with the per-100 g figures from that lookup and nutritionSource \"brand\". "
                + "If that lookup had no published figures for it, send it again unchanged "
                + "as an estimate and it will be accepted.")
            + "\"}"
    }

    /// The looked-up products that the call sends as estimates.
    static func productsSentAsEstimates(in arguments: [String: JSONValue],
                                        lookedUp products: [String]) -> [String] {
        estimatedItems(in: arguments, lookedUp: products).map(\.product)
    }

    /// Items that match a looked-up product but aren't from a brand or label.
    private static func estimatedItems(in arguments: [String: JSONValue],
                                       lookedUp products: [String])
        -> [(name: String, product: String)] {
        guard !products.isEmpty else { return [] }
        let items = AssistantToolExecutor.foods(in: arguments)
            .flatMap { $0["items"]?.arrayValue ?? [] }
            .compactMap(\.objectValue)
        return items.compactMap { item in
            let source = item["nutritionSource"]?.stringValue?.lowercased()
            guard source != "brand", source != "label", source != "saved",
                  let name = item["name"]?.stringValue,
                  let product = products.first(where: { matches(name, $0) }) else { return nil }
            return (name, product)
        }
    }

    /// Two product names share at least two significant words.
    static func matches(_ name: String, _ product: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
                .map(String.init).filter { $0.count >= 3 })
        }
        return words(name).intersection(words(product)).count >= 2
    }

    static func unsavedCardResult(for card: PendingAssistantWrite, tool: AssistantTool) -> String {
        let action = tool == .deleteFoodEntry
            ? "To drop it, just tell the user it won't be saved unless they confirm it."
            : "To change it, call addFoodEntry with the complete amended entry and "
                + "replacesCard set to \(card.id)."
        return "{\"status\":\"error\",\"detail\":\"\(escape(card.id)) is a card the user hasn't "
            + "confirmed yet, not a saved entry, so it has no entry id. \(escape(action))\"}"
    }

    static func cardTitle(for write: PendingAssistantWrite) -> String {
        switch write.action {
        case .add(let draft), .edit(_, let draft, _): draft.name
        case .delete(_, let name, _): name
        case .profile: "your profile"
        case .ranges: "your daily ranges"
        case .healthNotes: "your health notes"
        }
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
        case .profile(let update):
            "Update profile: " + update.lines.joined(separator: "; ")
        case .ranges(let update):
            "Change ranges: " + update.changes.map {
                "\($0.nutrient) \(AppFormatters.range($0.new))"
            }.joined(separator: "; ")
        case .healthNotes(let update):
            "Save health notes: " + update.notes.map(\.condition).joined(separator: ", ")
        }
        return "{\"status\":\"awaiting_user\",\"cardID\":\"\(escape(write.id))\","
            + "\"card\":\"\(escape(card))\",\"detail\":\"Shown to the user as a confirmation "
            + "card, not yet confirmed or cancelled. If the user now asks to change it, propose "
            + "the complete amended version with replacesCard set to this cardID and it will "
            + "replace this card. Otherwise answer them and leave the card as it is.\"}"
    }

    // MARK: Chat history

    /// Saves a chat - the one on screen unless another is given - once it has
    /// at least one message from the user.
    func persist(_ chat: ChatSession? = nil) {
        let chat = chat ?? session
        guard let historyStore,
              chat.messages.contains(where: { if case .user = $0.kind { return true }; return false })
        else { return }
        historyStore.save(SavedConversation(id: chat.id,
                                            title: SavedConversation.title(for: chat.messages),
                                            createdAt: chat.createdAt,
                                            // Time of the last message, not of saving:
                                            // saves also happen on opening history,
                                            // switching chats and leaving the app.
                                            updatedAt: chat.messages.last?.timestamp ?? chat.createdAt,
                                            messages: chat.messages,
                                            turns: chat.turns))
    }

    /// Saves the current chat and starts an empty one.
    func startNewConversation() {
        switchTo(ChatSession())
    }

    /// Reopens a chat so the user can read it or carry on. One still working
    /// or with open cards comes back live; any other is loaded from its save.
    func open(_ conversation: SavedConversation) {
        guard conversation.id != conversationID else { return }
        if let kept = keptSessions[conversation.id] {
            switchTo(kept)
            return
        }
        let chat = ChatSession(id: conversation.id, createdAt: conversation.createdAt)
        chat.messages = conversation.messages
        chat.turns = Self.closingUnansweredToolCalls(in: conversation.turns)
        switchTo(chat)
    }

    /// Puts another chat on screen. The one being left is saved, and kept in
    /// memory while its reply is still coming or its cards are still open, so
    /// the reply lands in it - not in the chat the user moved to.
    private func switchTo(_ next: ChatSession) {
        persist()
        finishReveal()
        if session.needsKeeping {
            keptSessions[session.id] = session
        } else {
            keptSessions[session.id] = nil
        }
        keptSessions[next.id] = nil
        session = next
        attachments = []
        composerText = ""
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

    // MARK: Transcript helpers

    /// Adds a message to a chat - the one on screen unless another is given.
    private func append(_ kind: AssistantChatMessage.Kind, to chat: ChatSession? = nil) {
        (chat ?? session).messages.append(AssistantChatMessage(kind: kind))
    }

    // MARK: Reply reveal

    /// Time between reveal steps, and the most steps a reply takes, so even a
    /// long reply is fully shown in about two and a half seconds.
    private static let revealTick: UInt64 = 30_000_000
    private static let maxRevealSteps = 80.0

    /// What the transcript shows for an assistant message: the part revealed
    /// so far while it is appearing, otherwise the whole text.
    func displayedText(_ text: String, for id: UUID) -> String {
        guard id == revealingMessageID else { return text }
        return String(text.prefix(revealedLength))
    }

    /// Shows the reply a few words at a time, like a streamed chat reply.
    private func reveal(_ id: UUID, text: String) {
        finishReveal()
        let stops = Self.revealStops(in: text)
        guard stops.count > 1 else { return }
        let step = max(1, Int((Double(stops.count) / Self.maxRevealSteps).rounded(.up)))
        revealingMessageID = id
        revealedLength = 0
        revealTask = Task { [weak self] in
            for index in stride(from: step - 1, to: stops.count, by: step) {
                try? await Task.sleep(nanoseconds: Self.revealTick)
                guard let self, !Task.isCancelled else { return }
                self.revealedLength = stops[index]
            }
            guard let self, !Task.isCancelled else { return }
            self.finishReveal()
        }
    }

    /// Shows the rest of the reply at once - when it finishes, or when the
    /// user sends again or switches chat.
    private func finishReveal() {
        revealTask?.cancel()
        revealTask = nil
        revealingMessageID = nil
        revealedLength = 0
    }

    /// Character counts at the end of each word, ending with the full length.
    static func revealStops(in text: String) -> [Int] {
        var stops: [Int] = []
        var previousWasSpace = true
        for (offset, character) in text.enumerated() {
            if character.isWhitespace, !previousWasSpace { stops.append(offset) }
            previousWasSpace = character.isWhitespace
        }
        if stops.last != text.count { stops.append(text.count) }
        return stops
    }

    private static func activityLabel(for tool: AssistantTool) -> String {
        switch tool {
        case .queryEntries: "Read your food log"
        case .getTrends: "Read your trends"
        case .calculateNutrition: "Worked out the nutrition"
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
        case .profile:
            "Profile updated. Daily ranges recalculated."
        case .ranges:
            "Daily ranges updated."
        case .healthNotes(let update):
            "Health notes saved (\(update.notes.count))."
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

/// One photo or file in the composer. `data` is nil while it is still being
/// loaded and downsized, which the composer shows as a spinner. `fileName` is
/// set for a file and nil for a photo.
struct ComposerAttachment: Identifiable, Equatable {
    let id = UUID()
    var fileName: String?
    var data: Data?
}
