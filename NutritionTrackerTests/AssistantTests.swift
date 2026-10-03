import XCTest
import SwiftData
@testable import NutritionTracker

// MARK: - Argument parsing

final class AssistantArgumentParsingTests: XCTestCase {

    func testValidAddParses() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Grilled Chicken Salad"),
            "quantity": .number(1),
            "servingSize": .number(1),
            "unit": .string("serving"),
            "calories": .number(380),
            "protein": .number(35),
            "carbs": .number(12),
            "fat": .number(20)
        ])
        XCTAssertEqual(draft.name, "Grilled Chicken Salad")
        XCTAssertEqual(draft.source, .assistant)
        XCTAssertEqual(draft.total.calories, 380)
        XCTAssertEqual(draft.total.protein, 35)
    }

    func testNumbersAsStringsTolerated() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Eggs"), "quantity": .string("2"), "unit": .string("piece"),
            "calories": .string("78"), "protein": .string("6,3")
        ])
        XCTAssertEqual(draft.quantity, 2)
        XCTAssertEqual(draft.unit, .piece)
        XCTAssertEqual(draft.total.calories, 156)
        XCTAssertEqual(draft.nutritionPerServing.protein, 6.3, accuracy: 0.001)
    }

    func testMissingNameRejected() {
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: ["calories": .number(100)]))
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: ["name": .string("   ")]))
    }

    func testNonPositiveQuantityRejected() {
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("X"), "quantity": .number(-2)]))
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("X"), "servingSize": .number(0)]))
    }

    func testHallucinatedUnitFallsBackToServing() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Soup"), "unit": .string("bowlful")])
        XCTAssertEqual(draft.unit, .serving)
    }

    func testNegativeAndNaNNutritionSanitised() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("X"), "calories": .number(-50), "protein": .string("NaN")])
        XCTAssertTrue(draft.nutritionPerServing.isValid)
        XCTAssertEqual(draft.nutritionPerServing.calories, 0)
    }

    func testCompositeAddClearsParentNutritionToAvoidDoubleCounting() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Nasi Lemak"),
            "calories": .number(9999),
            "ingredients": .array([
                .object(["name": .string("Coconut rice"), "quantity": .number(200),
                         "servingSize": .number(100), "unit": .string("gram"),
                         "calories": .number(180)]),
                .object(["name": .string("Egg"), "quantity": .number(1),
                         "servingSize": .number(1), "unit": .string("piece"),
                         "calories": .number(90)]),
                .object(["name": .string(""), "quantity": .number(5)]),   // dropped
                .object(["name": .string("Bad"), "quantity": .number(0)]) // dropped
            ])
        ])
        XCTAssertTrue(draft.isComposite)
        XCTAssertEqual(draft.ingredients.count, 2)
        XCTAssertEqual(draft.nutritionPerServing, .zero)
        XCTAssertEqual(draft.total.calories, 450, accuracy: 0.001)
    }

    func testDateParsingAcceptsISOAndBareDate() {
        XCTAssertNotNil(AssistantArgumentParser.parseDate(.string("2026-10-02T08:30:00Z")))
        XCTAssertNotNil(AssistantArgumentParser.parseDate(.string("2026-10-02")))
        XCTAssertNil(AssistantArgumentParser.parseDate(.string("yesterday-ish")))
    }

    func testInvalidEntryIdentifierRejected() {
        XCTAssertThrowsError(try AssistantArgumentParser.parseEntryID(.string("not-a-uuid"))) {
            XCTAssertEqual($0 as? AssistantToolError, .invalidIdentifier("not-a-uuid"))
        }
    }

    func testTrendScaleDefaultsToDaily() {
        XCTAssertEqual(AssistantArgumentParser.parseTrendScale(.string("weekly")), .weekly)
        XCTAssertEqual(AssistantArgumentParser.parseTrendScale(.string("fortnightly")), .daily)
        XCTAssertEqual(AssistantArgumentParser.parseTrendScale(nil), .daily)
    }

    func testToolWriteClassification() {
        XCTAssertTrue(AssistantTool.addFoodEntry.isWrite)
        XCTAssertTrue(AssistantTool.editFoodEntry.isWrite)
        XCTAssertTrue(AssistantTool.deleteFoodEntry.isWrite)
        XCTAssertFalse(AssistantTool.queryEntries.isWrite)
        XCTAssertFalse(AssistantTool.getTrends.isWrite)
    }

    func testEveryToolSchemaIsSerialisable() {
        for tool in AssistantTool.allCases {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool.inputSchema), tool.rawValue)
        }
    }
}

// MARK: - Provider response decoding

final class AssistantResponseDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> AssistantResponse {
        try OpenAICompatibleAssistantService.decode(data: Data(json.utf8))
    }

    func testDecodesTextAndToolCall() throws {
        let response = try decode("""
        {"choices": [{"message": {"role": "assistant", "content": "I can log that.",
          "tool_calls": [{"id": "call_1", "type": "function", "function": {
            "name": "addFoodEntry",
            "arguments": "{\\"name\\": \\"Nasi Lemak\\", \\"calories\\": 650, \\"quantity\\": 1}"}}]}}]}
        """)
        XCTAssertEqual(response.text, "I can log that.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].id, "call_1")
        XCTAssertEqual(response.toolCalls[0].tool, .addFoodEntry)
        XCTAssertEqual(response.toolCalls[0].arguments["calories"], .number(650))
    }

    func testArgumentsAsObjectAreAccepted() throws {
        let response = try decode("""
        {"choices": [{"message": {"tool_calls": [{"id": "c", "function": {
          "name": "getTrends", "arguments": {"timeframe": "weekly"}}}]}}]}
        """)
        XCTAssertEqual(response.toolCalls.first?.arguments["timeframe"], .string("weekly"))
        XCTAssertNil(response.text)
    }

    func testHallucinatedToolNameIsDropped() throws {
        let response = try decode("""
        {"choices": [{"message": {"tool_calls": [{"id": "t", "function": {
          "name": "orderPizza", "arguments": "{}"}}]}}]}
        """)
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    /// Some compatible APIs omit tool call ids; one is generated so the result
    /// can still be paired with its call.
    func testMissingToolCallIdIsGenerated() throws {
        let response = try decode("""
        {"choices": [{"message": {"tool_calls": [{"function": {
          "name": "queryEntries", "arguments": "{}"}}]}}]}
        """)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertFalse(response.toolCalls[0].id.isEmpty)
    }

    func testMalformedArgumentsBecomeEmpty() throws {
        let response = try decode("""
        {"choices": [{"message": {"tool_calls": [{"id": "c", "function": {
          "name": "queryEntries", "arguments": "{not json"}}]}}]}
        """)
        XCTAssertEqual(response.toolCalls.first?.arguments, [:])
    }

    func testMalformedEnvelopeThrows() {
        XCTAssertThrowsError(try decode("{\"nope\": 1}")) {
            guard case .malformedResponse = $0 as? AssistantServiceError else {
                return XCTFail("expected malformedResponse")
            }
        }
        XCTAssertThrowsError(try decode("{\"choices\": []}"))
    }
}

/// When Google retires a model name, the service picks a current one from the
/// provider's model list instead of failing with HTTP 404.
final class AssistantModelDiscoveryTests: XCTestCase {

    func testPrefersNewestStableFlash() {
        let picked = OpenAICompatibleAssistantService.pickModel(from: [
            "models/gemini-2.5-flash",
            "models/gemini-3.0-flash",
            "models/gemini-3.1-flash-preview",
            "models/gemini-3.0-flash-lite",
            "models/gemini-3.0-pro",
            "models/text-embedding-004"
        ], excluding: "gemini-2.5-flash")
        XCTAssertEqual(picked, "gemini-3.0-flash")
    }

    func testNeverReturnsTheModelThatJustFailed() {
        let picked = OpenAICompatibleAssistantService.pickModel(
            from: ["gemini-2.5-flash", "gemini-2.5-pro"], excluding: "gemini-2.5-flash")
        XCTAssertEqual(picked, "gemini-2.5-pro")
    }

    func testSkipsSpecialisedModels() {
        let picked = OpenAICompatibleAssistantService.pickModel(from: [
            "gemini-3.0-flash-image", "gemini-3.0-flash-tts", "gemini-embedding-001",
            "gemini-3.0-flash-live", "gemini-2.0-flash"
        ], excluding: "x")
        XCTAssertEqual(picked, "gemini-2.0-flash")
    }

    func testNoSuitableModelReturnsNil() {
        XCTAssertNil(OpenAICompatibleAssistantService.pickModel(
            from: ["text-embedding-004", "imagen-4"], excluding: "x"))
    }

    func testStatusMapping() {
        XCTAssertThrowsError(try OpenAICompatibleAssistantService.check(status: 404, model: "m")) {
            XCTAssertEqual($0 as? AssistantServiceError, .modelUnavailable(model: "m"))
        }
        XCTAssertThrowsError(try OpenAICompatibleAssistantService.check(status: 429, model: "m")) {
            XCTAssertEqual($0 as? AssistantServiceError, .rateLimited)
        }
        XCTAssertNoThrow(try OpenAICompatibleAssistantService.check(status: 200, model: "m"))
    }
}

final class AssistantRequestEncodingTests: XCTestCase {

    func testToolResultsBecomeSeparateToolMessages() {
        let turn = AssistantTurn(role: .user, blocks: [
            .toolResult(id: "a", content: "{\"x\":1}", isError: false),
            .toolResult(id: "b", content: "{\"y\":2}", isError: false)
        ])
        let messages = OpenAICompatibleAssistantService.encode(turn: turn)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "tool")
        XCTAssertEqual(messages[0]["tool_call_id"] as? String, "a")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "b")
    }

    func testAssistantToolCallsCarryJSONStringArguments() throws {
        let turn = AssistantTurn(role: .assistant, blocks: [
            .text("Logging it."),
            .toolUse(id: "c1", name: "addFoodEntry", input: ["name": .string("Teh Tarik")])
        ])
        let messages = OpenAICompatibleAssistantService.encode(turn: turn)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["content"] as? String, "Logging it.")
        let calls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        XCTAssertTrue(arguments.contains("Teh Tarik"))
    }

    func testMenuPhotoBecomesImagePart() throws {
        let turn = AssistantTurn(role: .user, blocks: [.image(Data([1, 2, 3])), .text("What fits?")])
        let messages = OpenAICompatibleAssistantService.encode(turn: turn)
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "image_url")
        let url = (parts.first?["image_url"] as? [String: Any])?["url"] as? String
        XCTAssertTrue(url?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(parts.last?["text"] as? String, "What fits?")
    }

    func testBodyHasSystemContextAndFunctionTools() throws {
        let body = OpenAICompatibleAssistantService.makeBody(
            model: "test-model", turns: [.user("hi")], contextJSON: "{\"k\":1}",
            tools: AssistantTool.allCases)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertEqual(body["model"] as? String, "test-model")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("{\"k\":1}") == true)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AssistantTool.allCases.count)
        XCTAssertEqual(tools.first?["type"] as? String, "function")
    }
}

// MARK: - Executor and the confirmation gate

@MainActor
final class AssistantToolExecutorTests: XCTestCase {

    private func count(_ context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<FoodEntry>())) ?? -1
    }

    func testAddProposesButDoesNotWrite() {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        let outcome = executor.execute(AssistantToolCall(
            id: "1", tool: .addFoodEntry,
            arguments: ["name": .string("Teh Tarik"), "calories": .number(150)]))

        XCTAssertTrue(outcome.isWriteProposal)
        XCTAssertEqual(count(context), 0, "nothing written before confirmation")
    }

    func testCommitIsTheOnlyWritePath() throws {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "1", tool: .addFoodEntry,
            arguments: ["name": .string("Teh Tarik"), "calories": .number(150)])) else {
            return XCTFail("expected a proposal")
        }
        let result = try executor.commit(write)
        XCTAssertTrue(result.contains("\"added\""))
        XCTAssertEqual(count(context), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FoodEntry>()).first?.source, .assistant)
    }

    func testDeclineWritesNothing() {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "1", tool: .addFoodEntry, arguments: ["name": .string("X"), "calories": .number(1)]))
        else { return XCTFail() }

        let result = executor.declinedResult(for: write)
        XCTAssertTrue(result.contains("declined"))
        XCTAssertEqual(count(context), 0)
    }

    func testDeleteRequiresConfirmationToo() throws {
        let context = TestSupport.makeContext()
        let entry = TestSupport.entry(name: "Roti Canai", at: .now)
        context.insert(entry)
        try context.save()

        let executor = AssistantToolExecutor(context: context)
        let outcome = executor.execute(AssistantToolCall(
            id: "d", tool: .deleteFoodEntry, arguments: ["id": .string(entry.id.uuidString)]))
        guard case .awaitingConfirmation(let write) = outcome else { return XCTFail() }
        XCTAssertTrue(write.isDestructive)
        XCTAssertEqual(count(context), 1, "still present until confirmed")

        try executor.commit(write)
        XCTAssertEqual(count(context), 0)
    }

    func testEditChangesOnlyProvidedFields() throws {
        let context = TestSupport.makeContext()
        let entry = FoodEntry(name: "Chicken", quantity: 100, servingSize: 100, unit: .gram,
                              nutritionPerServing: Nutrition(calories: 165, protein: 31, fat: 3.6))
        context.insert(entry)
        try context.save()

        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "e", tool: .editFoodEntry,
            arguments: ["id": .string(entry.id.uuidString), "quantity": .number(150)])) else {
            return XCTFail()
        }
        XCTAssertEqual(entry.quantity, 100, "not applied before confirmation")

        try executor.commit(write)
        XCTAssertEqual(entry.quantity, 150)
        XCTAssertEqual(entry.name, "Chicken", "unspecified fields untouched")
        XCTAssertEqual(entry.nutritionPerServing.protein, 31)
        XCTAssertEqual(entry.total.calories, 247.5, accuracy: 0.001)
    }

    func testEditOfDeletedEntryFailsCleanly() {
        let executor = AssistantToolExecutor(context: TestSupport.makeContext())
        let missing = UUID()
        let outcome = executor.execute(AssistantToolCall(
            id: "e", tool: .editFoodEntry,
            arguments: ["id": .string(missing.uuidString), "quantity": .number(2)]))
        guard case .failure(let message) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("no longer exists"))
    }

    /// The entry disappears between proposal and confirmation (e.g. deleted on
    /// the Dashboard while the card was showing).
    func testCommitAfterEntryDeletedThrows() throws {
        let context = TestSupport.makeContext()
        let entry = TestSupport.entry(at: .now)
        context.insert(entry)
        try context.save()

        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "d", tool: .deleteFoodEntry, arguments: ["id": .string(entry.id.uuidString)]))
        else { return XCTFail() }

        context.delete(entry)
        try context.save()

        XCTAssertThrowsError(try executor.commit(write)) {
            XCTAssertEqual($0 as? AssistantToolError, .entryNotFound(id: entry.id.uuidString))
        }
    }

    func testQueryEntriesIsReadOnlyAndReturnsTotals() throws {
        let context = TestSupport.makeContext()
        context.insert(TestSupport.entry(name: "Lunch", at: .now, calories: 600))
        try context.save()

        let outcome = AssistantToolExecutor(context: context)
            .execute(AssistantToolCall(id: "q", tool: .queryEntries, arguments: [:]))
        guard case .result(let json) = outcome else { return XCTFail() }
        XCTAssertTrue(json.contains("\"entryCount\":1"))
        XCTAssertTrue(json.contains("Lunch"))
        XCTAssertEqual(count(context), 1)
    }

    func testQueryRejectsInvertedRange() {
        let outcome = AssistantToolExecutor(context: TestSupport.makeContext()).execute(
            AssistantToolCall(id: "q", tool: .queryEntries,
                              arguments: ["startDate": .string("2026-10-05"),
                                          "endDate": .string("2026-10-01")]))
        guard case .failure = outcome else { return XCTFail("expected failure") }
    }

    func testGetTrendsReturnsStatesAgainstTargets() throws {
        let context = TestSupport.makeContext()
        context.insert(NutritionTarget(ranges: TestSupport.ranges()))
        context.insert(TestSupport.entry(at: .now, calories: 2500))
        try context.save()

        let outcome = AssistantToolExecutor(context: context).execute(
            AssistantToolCall(id: "t", tool: .getTrends, arguments: ["timeframe": .string("daily")]))
        guard case .result(let json) = outcome else { return XCTFail() }
        XCTAssertTrue(json.contains("\"calories\":\"over\""))
        XCTAssertTrue(json.contains("\"plots\":\"daily total\""))
    }
}

// MARK: - Context payload

@MainActor
final class AssistantContextBuilderTests: XCTestCase {

    func testPayloadContainsRemainingRoomAndTodaysEntries() throws {
        let context = TestSupport.makeContext()
        context.insert(UserProfile(dateOfBirth: TestSupport.date(1990, 1, 1), sex: .female,
                                   heightCm: 165, weightKg: 60, targetWeightKg: 55,
                                   goal: .loseWeight, activity: .light, bodyFatPercent: 28))
        context.insert(NutritionTarget(ranges: TestSupport.ranges()))
        context.insert(TestSupport.entry(name: "Breakfast", at: .now, calories: 400, protein: 20))
        try context.save()

        let payload = AssistantContextBuilder(context: context).build()

        XCTAssertEqual(payload.entriesToday.map(\.name), ["Breakfast"])
        let calories = try XCTUnwrap(payload.targetRanges.first { $0.nutrient == "calories" })
        XCTAssertEqual(calories.consumedToday, 400)
        XCTAssertEqual(calories.remainingToMax, 1800)
        XCTAssertEqual(calories.neededToReachMin, 1400)
        XCTAssertEqual(calories.state, "under")
        XCTAssertNotNil(payload.trend)
        XCTAssertEqual(payload.profile?.goal, "loseWeight")
    }

    /// Only what the assistant needs leaves the device (spec sections 29A, 39).
    func testPayloadOmitsUnneededPersonalDetail() throws {
        let context = TestSupport.makeContext()
        context.insert(UserProfile(dateOfBirth: TestSupport.date(1990, 1, 1), sex: .female,
                                   heightCm: 165, weightKg: 60, targetWeightKg: 55,
                                   goal: .loseWeight, activity: .light, bodyFatPercent: 28))
        try context.save()

        let json = try AssistantContextBuilder(context: context).encodedJSON()
        XCTAssertFalse(json.contains("dateOfBirth"))
        XCTAssertFalse(json.contains("bodyFat"))
        XCTAssertFalse(json.contains("targetWeight"))
        XCTAssertFalse(json.lowercased().contains("photo"))
    }

    func testPayloadScopedToTodayNotWholeDatabase() throws {
        let context = TestSupport.makeContext()
        let lastMonth = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -40, to: .now)!
        for index in 0..<50 {
            context.insert(TestSupport.entry(name: "Old \(index)", at: lastMonth))
        }
        context.insert(TestSupport.entry(name: "Now", at: .now))
        try context.save()

        let payload = AssistantContextBuilder(context: context).build()
        XCTAssertEqual(payload.entriesToday.count, 1)
        XCTAssertFalse(try AssistantContextBuilder(context: context).encodedJSON().contains("Old 0"))
    }
}

// MARK: - View model loop with a scripted provider

final class ScriptedAssistantService: AssistantServing, @unchecked Sendable {
    var responses: [AssistantResponse]
    private(set) var receivedTurns: [[AssistantTurn]] = []

    init(_ responses: [AssistantResponse]) { self.responses = responses }

    var isConfigured: Bool { true }

    func send(turns: [AssistantTurn], contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {
        receivedTurns.append(turns)
        guard !responses.isEmpty else { return AssistantResponse(text: "Done.", toolCalls: []) }
        return responses.removeFirst()
    }
}

@MainActor
final class AssistantViewModelTests: XCTestCase {

    private func makeViewModel(_ service: AssistantServing) -> (AssistantViewModel, ModelContext) {
        let context = TestSupport.makeContext()
        let viewModel = AssistantViewModel(service: service,
                                           executor: AssistantToolExecutor(context: context),
                                           contextBuilder: AssistantContextBuilder(context: context))
        return (viewModel, context)
    }

    private let addCall = AssistantResponse(
        text: "Proposing that now.",
        toolCalls: [AssistantToolCall(id: "toolu_add", tool: .addFoodEntry,
                                      arguments: ["name": .string("Grilled Chicken Salad"),
                                                  "calories": .number(380),
                                                  "protein": .number(35)])])

    /// Flow J: propose -> confirmation card -> confirm -> saved.
    func testConfirmedWriteIsSaved() async throws {
        let service = ScriptedAssistantService([addCall,
                                                AssistantResponse(text: "Logged it.", toolCalls: [])])
        let (viewModel, context) = makeViewModel(service)

        viewModel.composerText = "log the grilled chicken salad"
        await viewModel.send()

        XCTAssertNotNil(viewModel.pendingWrite, "loop pauses on a write")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 0)
        XCTAssertFalse(viewModel.canSend, "cannot send while a confirmation is open")

        await viewModel.confirmPendingWrite()

        XCTAssertNil(viewModel.pendingWrite)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 1)

        // The provider must have received a tool_result for its tool_use.
        let lastTurns = try XCTUnwrap(service.receivedTurns.last)
        let resultBlocks = lastTurns.last?.blocks ?? []
        XCTAssertTrue(resultBlocks.contains {
            if case .toolResult(let id, let content, false) = $0 {
                return id == "toolu_add" && content.contains("added")
            }
            return false
        })
    }

    func testDeclinedWriteIsNotSavedAndModelIsTold() async throws {
        let service = ScriptedAssistantService([addCall,
                                                AssistantResponse(text: "No problem.", toolCalls: [])])
        let (viewModel, context) = makeViewModel(service)

        viewModel.composerText = "log it"
        await viewModel.send()
        await viewModel.declinePendingWrite()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 0)
        let resultBlocks = service.receivedTurns.last?.last?.blocks ?? []
        XCTAssertTrue(resultBlocks.contains {
            if case .toolResult(_, let content, _) = $0 { return content.contains("declined") }
            return false
        })
    }

    /// The assistant's own replies must be sent back on the next request, or
    /// follow-up questions lose their context.
    func testAssistantRepliesAreKeptInHistory() async throws {
        let service = ScriptedAssistantService([
            AssistantResponse(text: "Try the grilled chicken salad.", toolCalls: []),
            AssistantResponse(text: "Sure.", toolCalls: [])
        ])
        let (viewModel, _) = makeViewModel(service)

        viewModel.composerText = "what should I eat?"
        await viewModel.send()
        viewModel.composerText = "something lighter?"
        await viewModel.send()

        let second = try XCTUnwrap(service.receivedTurns.last)
        XCTAssertEqual(second.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(second[1].blocks, [.text("Try the grilled chicken salad.")])
    }

    func testReadToolRunsWithoutConfirmation() async throws {
        let service = ScriptedAssistantService([
            AssistantResponse(text: nil, toolCalls: [
                AssistantToolCall(id: "q", tool: .queryEntries, arguments: [:])]),
            AssistantResponse(text: "You've logged nothing yet today.", toolCalls: [])
        ])
        let (viewModel, _) = makeViewModel(service)

        viewModel.composerText = "what have I eaten?"
        await viewModel.send()

        XCTAssertNil(viewModel.pendingWrite)
        XCTAssertEqual(service.receivedTurns.count, 2)
        XCTAssertTrue(viewModel.messages.contains {
            if case .assistant(let text) = $0.kind { return text.contains("nothing yet") }
            return false
        })
    }

    func testToolCallsAfterAWriteAreDeferredNotDropped() async throws {
        let service = ScriptedAssistantService([
            AssistantResponse(text: nil, toolCalls: [
                AssistantToolCall(id: "a", tool: .addFoodEntry,
                                  arguments: ["name": .string("X"), "calories": .number(1)]),
                AssistantToolCall(id: "b", tool: .getTrends, arguments: [:])
            ])
        ])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "go"
        await viewModel.send()
        await viewModel.declinePendingWrite()

        let ids = (service.receivedTurns.last?.last?.blocks ?? []).compactMap { block -> String? in
            if case .toolResult(let id, _, _) = block { return id }
            return nil
        }
        XCTAssertEqual(Set(ids), ["a", "b"], "every tool_use gets a result")
    }

    /// A build without the assistant key: unavailable, and nothing is sent.
    func testUnconfiguredServiceIsUnavailableAndSendsNothing() async {
        let (viewModel, _) = makeViewModel(UnconfiguredAssistantService())
        XCTAssertFalse(viewModel.isAvailable)
        viewModel.composerText = "hello"
        XCTAssertFalse(viewModel.canSend)

        await viewModel.send()
        XCTAssertTrue(viewModel.messages.contains {
            if case .error(let text) = $0.kind { return text.contains("isn't available") }
            return false
        })
    }

    func testConfiguredServiceIsAvailableWithoutAnySetup() {
        let (viewModel, _) = makeViewModel(ScriptedAssistantService([]))
        XCTAssertTrue(viewModel.isAvailable)
        viewModel.composerText = "hello"
        XCTAssertTrue(viewModel.canSend)
    }

    func testRunawayToolLoopIsBounded() async {
        let looping = (0..<10).map { index in
            AssistantResponse(text: nil, toolCalls: [
                AssistantToolCall(id: "q\(index)", tool: .queryEntries, arguments: [:])])
        }
        let service = ScriptedAssistantService(looping)
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "loop"
        await viewModel.send()
        XCTAssertLessThanOrEqual(service.receivedTurns.count, 5)
        XCTAssertTrue(viewModel.messages.contains {
            if case .error = $0.kind { return true }
            return false
        })
    }
}
