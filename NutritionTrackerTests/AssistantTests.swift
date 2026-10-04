import XCTest
import SwiftData
@testable import NutritionTracker

// MARK: - Argument parsing

final class AssistantArgumentParsingTests: XCTestCase {

    private func item(_ name: String, grams: JSONValue,
                      kcal: Double? = nil, protein: Double? = nil,
                      carbs: Double? = nil, fat: Double? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["name": .string(name), "grams": grams]
        if let kcal { object["kcalPer100g"] = .number(kcal) }
        if let protein { object["proteinPer100g"] = .number(protein) }
        if let carbs { object["carbsPer100g"] = .number(carbs) }
        if let fat { object["fatPer100g"] = .number(fat) }
        return .object(object)
    }

    func testSingleItemBecomesGramBasedSimpleFood() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Grilled Chicken"),
            "items": .array([item("chicken breast", grams: .number(150),
                                  kcal: 165, protein: 31, carbs: 0, fat: 3.6)])
        ])
        XCTAssertFalse(draft.isComposite)
        XCTAssertEqual(draft.source, .assistant)
        XCTAssertEqual(draft.unit, .gram)
        XCTAssertEqual(draft.quantity, 150)
        XCTAssertEqual(draft.servingSize, 100)
        XCTAssertEqual(draft.total.calories, 247.5, accuracy: 0.5)
    }

    func testSeveralItemsBecomeCompositeWithNoParentTotal() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Nasi Lemak"),
            "items": .array([
                item("coconut rice", grams: .number(200), kcal: 180, protein: 3, carbs: 28, fat: 6),
                item("fried egg", grams: .number(50), kcal: 196, protein: 13.6, carbs: 0.8, fat: 15.3),
                item("", grams: .number(5)),                 // dropped: no name
                item("sambal", grams: .number(0), kcal: 100) // dropped: no grams
            ])
        ])
        XCTAssertTrue(draft.isComposite)
        XCTAssertEqual(draft.ingredients.count, 2)
        XCTAssertEqual(draft.nutritionPerServing, .zero, "totals come only from the items")
        XCTAssertTrue(draft.ingredients.allSatisfy { $0.unit == .gram && $0.servingSize == 100 })
        XCTAssertTrue(draft.ingredients.allSatisfy { $0.provenance == .modelEstimate })
    }

    func testNumbersAsStringsTolerated() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Eggs"),
            "items": .array([.object(["name": .string("egg"), "grams": .string("100"),
                                      "proteinPer100g": .string("12,6")])])
        ])
        XCTAssertEqual(draft.quantity, 100)
        XCTAssertEqual(draft.nutritionPerServing.protein, 12.6, accuracy: 0.001)
    }

    func testMissingNameOrItemsRejected() {
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: [
            "items": .array([item("egg", grams: .number(50))])]))
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: ["name": .string("   ")]))
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: ["name": .string("Lunch")]),
                             "a meal with no components is rejected")
    }

    func testImplausibleGramsDropped() throws {
        XCTAssertThrowsError(try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("X"),
            "items": .array([item("a", grams: .number(-20)),
                             item("b", grams: .number(5000))])]))
    }

    /// The model's per-100 g guesses are repaired when they can't be right.
    func testPlausibilityRepairsEstimates() {
        // Calories far from what the macros imply: macros win.
        let mismatched = AssistantArgumentParser.plausiblePer100g(
            Nutrition(calories: 400, protein: 0.2, carbs: 3, fat: 0.1))
        XCTAssertEqual(mismatched.calories, (0.2 * 4 + 3 * 4 + 0.1 * 9).rounded())

        // Close enough: the stated figure is kept.
        let close = AssistantArgumentParser.plausiblePer100g(
            Nutrition(calories: 160, protein: 13, carbs: 1, fat: 11))
        XCTAssertEqual(close.calories, 160)

        // Nothing is denser than pure fat; negatives and NaN are cleaned.
        let absurd = AssistantArgumentParser.plausiblePer100g(Nutrition(calories: 5000))
        XCTAssertEqual(absurd.calories, 900)
        let broken = AssistantArgumentParser.plausiblePer100g(Nutrition(calories: -50, protein: .nan))
        XCTAssertTrue(broken.isValid)
    }

    func testResolverIsAppliedToEveryItem() throws {
        let draft = try AssistantArgumentParser.parseAdd(arguments: [
            "name": .string("Plate"),
            "items": .array([item("a", grams: .number(100)), item("b", grams: .number(100))])
        ]) { item in
            var resolved = item
            resolved.provenance = .genericDatabase
            return resolved
        }
        XCTAssertTrue(draft.ingredients.allSatisfy { $0.provenance == .genericDatabase })
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

    /// Flash-Lite first, for its much higher free daily limit on the shared key.
    func testPrefersNewestStableFlashLite() {
        let picked = OpenAICompatibleAssistantService.pickModel(from: [
            "models/gemini-3.8-flash",
            "models/gemini-3.0-flash-lite",
            "models/gemini-3.5-flash-lite",
            "models/gemini-3.9-flash-lite-preview",
            "models/gemini-3.0-pro",
            "models/text-embedding-004"
        ], excluding: "gemini-2.5-flash-lite")
        XCTAssertEqual(picked, "gemini-3.5-flash-lite")
    }

    func testFallsBackToNewestStableFlashWithoutLite() {
        let picked = OpenAICompatibleAssistantService.pickModel(from: [
            "models/gemini-2.5-flash",
            "models/gemini-3.0-flash",
            "models/gemini-3.1-flash-preview",
            "models/gemini-3.0-pro"
        ], excluding: "x")
        XCTAssertEqual(picked, "gemini-3.0-flash")
    }

    func testDefaultIsFlashLite() {
        XCTAssertTrue(OpenAICompatibleAssistantService.defaultModel.contains("flash-lite"))
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
        XCTAssertThrowsError(try OpenAICompatibleAssistantService.check(status: 503, model: "m")) {
            XCTAssertEqual($0 as? AssistantServiceError, .providerBusy(status: 503))
        }
        XCTAssertNoThrow(try OpenAICompatibleAssistantService.check(status: 200, model: "m"))
    }

    /// Overloaded-server responses are retried; client errors are not.
    func testOnlyServerOverloadIsRetried() {
        for status in [500, 502, 503, 504] {
            XCTAssertTrue(OpenAICompatibleAssistantService.isTransient(status), "\(status)")
        }
        for status in [200, 400, 401, 404, 429] {
            XCTAssertFalse(OpenAICompatibleAssistantService.isTransient(status), "\(status)")
        }
    }
}

/// Gemini attaches a thought signature to each tool call and rejects the
/// follow-up request (HTTP 400) unless it is sent back unchanged.
final class AssistantThoughtSignatureTests: XCTestCase {

    func testSignatureIsKeptWhenDecoding() throws {
        let response = try OpenAICompatibleAssistantService.decode(data: Data("""
        {"choices": [{"message": {"tool_calls": [{"id": "c1", "type": "function",
          "function": {"name": "addFoodEntry", "arguments": "{\\"name\\": \\"Teh Tarik\\"}"},
          "extra_content": {"google": {"thought_signature": "SIG123"}}}]}}]}
        """.utf8))
        XCTAssertEqual(response.toolCalls.first?.extra,
                       .object(["google": .object(["thought_signature": .string("SIG123")])]))
    }

    func testSignatureIsSentBackWithTheToolCall() throws {
        let extra: JSONValue = .object(["google": .object(["thought_signature": .string("SIG123")])])
        let turn = AssistantTurn(role: .assistant, blocks: [
            .toolUse(id: "c1", name: "addFoodEntry", input: [:], extra: extra)
        ])
        let message = try XCTUnwrap(OpenAICompatibleAssistantService.encode(turn: turn).first)
        let call = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)
        let google = (call["extra_content"] as? [String: Any])?["google"] as? [String: Any]
        XCTAssertEqual(google?["thought_signature"] as? String, "SIG123")
    }

    func testNoSignatureMeansNoExtraField() throws {
        let turn = AssistantTurn(role: .assistant, blocks: [
            .toolUse(id: "c1", name: "getTrends", input: [:])
        ])
        let message = try XCTUnwrap(OpenAICompatibleAssistantService.encode(turn: turn).first)
        let call = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertNil(call["extra_content"])
    }

    func testProviderErrorMessageIsExtractedAndShort() {
        let body = Data(#"[{"error": {"code": 400, "message": "Function call is missing a thought_signature.\nMore detail here."}}]"#.utf8)
        XCTAssertEqual(OpenAICompatibleAssistantService.providerErrorMessage(from: body),
                       "Function call is missing a thought_signature.")
        XCTAssertNil(OpenAICompatibleAssistantService.providerErrorMessage(from: Data("oops".utf8)))
        XCTAssertThrowsError(try OpenAICompatibleAssistantService.check(status: 400, model: "m", body: body)) {
            XCTAssertEqual($0 as? AssistantServiceError,
                           .requestFailed(detail: "HTTP 400 - Function call is missing a thought_signature."))
        }
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

    static let tehTarikArguments: [String: JSONValue] = [
        "name": .string("Teh Tarik"),
        "items": .array([.object(["name": .string("teh tarik"), "grams": .number(250),
                                  "kcalPer100g": .number(60)])])
    ]

    static let tinyArguments: [String: JSONValue] = [
        "name": .string("X"),
        "items": .array([.object(["name": .string("x"), "grams": .number(10),
                                  "kcalPer100g": .number(10)])])
    ]

    /// The reported bug: a ~300 kcal konjac, tomato and egg plate logged at
    /// 1,000 kcal. Even with a wildly wrong guess for the konjac, the
    /// database values replace it and the total comes out realistic.
    func testKonjacTomatoEggPlateUsesDatabaseNotGuess() throws {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        let outcome = executor.execute(AssistantToolCall(
            id: "k", tool: .addFoodEntry,
            arguments: [
                "name": .string("Tomato egg with konjac"),
                "items": .array([
                    .object(["name": .string("konjac knots"), "grams": .number(150),
                             "kcalPer100g": .number(400)]),   // badly wrong guess
                    .object(["name": .string("eggs"), "grams": .number(100)]),
                    .object(["name": .string("tomatoes"), "grams": .number(120)]),
                    .object(["name": .string("cooking oil"), "grams": .number(10)])
                ])
            ]))
        guard case .awaitingConfirmation(let write) = outcome,
              case .add(let draft) = write.action else {
            return XCTFail("expected an add proposal")
        }
        XCTAssertLessThan(draft.total.calories, 400, "was ~1,000 before the fix")
        XCTAssertGreaterThan(draft.total.calories, 150)
        let konjac = try XCTUnwrap(draft.ingredients.first { $0.name == "konjac knots" })
        XCTAssertEqual(konjac.provenance, .genericDatabase, "database replaced the guess")
        XCTAssertEqual(konjac.canonicalID, "gen.konjac")
        XCTAssertTrue(draft.ingredients.allSatisfy { !$0.provenance.isEstimate },
                      "plurals and oil all matched the database")
    }

    private func count(_ context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<FoodEntry>())) ?? -1
    }

    func testAddProposesButDoesNotWrite() {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        let outcome = executor.execute(AssistantToolCall(
            id: "1", tool: .addFoodEntry,
            arguments: AssistantToolExecutorTests.tehTarikArguments))

        XCTAssertTrue(outcome.isWriteProposal)
        XCTAssertEqual(count(context), 0, "nothing written before confirmation")
    }

    func testCommitIsTheOnlyWritePath() throws {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "1", tool: .addFoodEntry,
            arguments: AssistantToolExecutorTests.tehTarikArguments)) else {
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
            id: "1", tool: .addFoodEntry, arguments: AssistantToolExecutorTests.tinyArguments))
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
                                                  "items": .array([.object([
                                                      "name": .string("grilled chicken salad"),
                                                      "grams": .number(300),
                                                      "kcalPer100g": .number(127)])])])])

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

    /// Every tool result anywhere in a request, as (id, content).
    private func toolResults(in turns: [AssistantTurn]) -> [(id: String, content: String)] {
        turns.flatMap(\.blocks).compactMap { block in
            if case .toolResult(let id, let content, _) = block { return (id, content) }
            return nil
        }
    }

    private func texts(in turn: AssistantTurn?) -> [String] {
        (turn?.blocks ?? []).compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }
    }

    /// Flow J: propose -> confirmation card -> confirm -> saved, with no extra
    /// reply from the assistant.
    func testConfirmedWriteIsSaved() async throws {
        let service = ScriptedAssistantService([addCall,
                                                AssistantResponse(text: "Noted.", toolCalls: [])])
        let (viewModel, context) = makeViewModel(service)

        viewModel.composerText = "I had a grilled chicken salad"
        await viewModel.send()

        XCTAssertNotNil(viewModel.pendingWrite, "loop pauses on a write")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 0)

        await viewModel.confirmPendingWrite()

        XCTAssertNil(viewModel.pendingWrite)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 1)
        XCTAssertEqual(service.receivedTurns.count, 1, "confirming doesn't ask the model to reply")

        // The outcome reaches the model with the next message.
        viewModel.composerText = "thanks"
        await viewModel.send()
        let next = try XCTUnwrap(service.receivedTurns.last)
        XCTAssertTrue(toolResults(in: next).contains { $0.id == "toolu_add" && $0.content.contains("added") })
    }

    func testDeclinedWriteIsNotSavedAndModelHearsNextTime() async throws {
        let service = ScriptedAssistantService([addCall,
                                                AssistantResponse(text: "Sure.", toolCalls: [])])
        let (viewModel, context) = makeViewModel(service)

        viewModel.composerText = "I had a salad"
        await viewModel.send()
        await viewModel.declinePendingWrite()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 0)
        XCTAssertEqual(service.receivedTurns.count, 1, "cancelling doesn't ask the model to reply")

        viewModel.composerText = "ok"
        await viewModel.send()
        let next = try XCTUnwrap(service.receivedTurns.last)
        XCTAssertTrue(toolResults(in: next).contains { $0.content.contains("declined") })
    }

    /// The card is the whole reply: text sent alongside a proposal isn't shown.
    func testTextAlongsideAProposalIsHidden() async {
        let (viewModel, _) = makeViewModel(ScriptedAssistantService([addCall]))
        viewModel.composerText = "I had a salad"
        await viewModel.send()

        XCTAssertFalse(viewModel.messages.contains {
            if case .assistant = $0.kind { return true }
            return false
        })
        XCTAssertTrue(viewModel.messages.contains {
            if case .proposal = $0.kind { return true }
            return false
        })
    }

    /// Chatting about something else keeps the card open to confirm later.
    func testUnrelatedMessageKeepsTheCardOpen() async throws {
        let service = ScriptedAssistantService([
            addCall,
            AssistantResponse(text: "You've had about 600 kcal so far.", toolCalls: [])
        ])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "I had a salad"
        await viewModel.send()
        let card = try XCTUnwrap(viewModel.pendingWrite)

        viewModel.composerText = "how many calories so far?"
        XCTAssertTrue(viewModel.canSend, "sending is allowed while a card is open")
        await viewModel.send()

        XCTAssertEqual(viewModel.pendingWrite?.id, card.id, "card still open")
        XCTAssertTrue(viewModel.replacedWriteIDs.isEmpty)
        // The model was told the card is waiting, before the new message.
        let request = try XCTUnwrap(service.receivedTurns.last)
        XCTAssertTrue(toolResults(in: request).contains {
            $0.id == "toolu_add" && $0.content.contains("awaiting_user")
        })
        XCTAssertTrue(viewModel.messages.contains {
            if case .assistant(let text) = $0.kind { return text.contains("600 kcal") }
            return false
        })
    }

    /// Asking for a change makes the model propose again: the new card
    /// replaces the old one.
    func testAmendmentReplacesTheOpenCard() async throws {
        let amended = AssistantResponse(text: nil, toolCalls: [
            AssistantToolCall(id: "toolu_add2", tool: .addFoodEntry,
                              arguments: AssistantToolExecutorTests.tinyArguments)])
        let service = ScriptedAssistantService([addCall, amended])
        let (viewModel, _) = makeViewModel(service)

        viewModel.composerText = "I had a salad"
        await viewModel.send()
        let first = try XCTUnwrap(viewModel.pendingWrite)

        viewModel.composerText = "add some rice too"
        await viewModel.send()

        XCTAssertEqual(viewModel.pendingWrite?.id, "toolu_add2")
        XCTAssertTrue(viewModel.replacedWriteIDs.contains(first.id))
    }

    /// Confirming a card after chatting on: the model learns via a note with
    /// the next message, not a fresh request.
    func testConfirmingAfterChattingSendsANoteNextTime() async throws {
        let service = ScriptedAssistantService([
            addCall,
            AssistantResponse(text: "About 600 kcal.", toolCalls: []),
            AssistantResponse(text: "Great.", toolCalls: [])
        ])
        let (viewModel, context) = makeViewModel(service)
        viewModel.composerText = "I had a salad"
        await viewModel.send()
        viewModel.composerText = "calories so far?"
        await viewModel.send()

        await viewModel.confirmPendingWrite()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 1)
        XCTAssertEqual(service.receivedTurns.count, 2, "no request on confirm")

        viewModel.composerText = "thanks"
        await viewModel.send()
        let note = texts(in: service.receivedTurns.last?.last).first { $0.hasPrefix("[Note:") }
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("confirmed") == true)
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
                                  arguments: AssistantToolExecutorTests.tinyArguments),
                AssistantToolCall(id: "b", tool: .getTrends, arguments: [:])
            ]),
            AssistantResponse(text: "Ok.", toolCalls: [])
        ])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "I had something"
        await viewModel.send()
        await viewModel.declinePendingWrite()
        viewModel.composerText = "next"
        await viewModel.send()

        let ids = toolResults(in: service.receivedTurns.last ?? []).map(\.id)
        XCTAssertEqual(Set(ids), ["a", "b"], "every tool call gets a result")
    }

    /// A build without the assistant key: unavailable, and nothing is sent.
    // MARK: Photo attachments

    func testLoadingPhotoBlocksSendingUntilReady() throws {
        let (viewModel, _) = makeViewModel(ScriptedAssistantService([]))
        let id = try XCTUnwrap(viewModel.beginAttachment())
        XCTAssertTrue(viewModel.isLoadingAttachment)
        XCTAssertFalse(viewModel.canSend, "can't send while a photo is still loading")

        viewModel.finishAttachment(id: id, data: Data([1, 2, 3]))
        XCTAssertFalse(viewModel.isLoadingAttachment)
        XCTAssertTrue(viewModel.canSend, "a photo alone is enough to send")
    }

    func testUnreadablePhotoRemovesItsPlaceholder() throws {
        let (viewModel, _) = makeViewModel(ScriptedAssistantService([]))
        let id = try XCTUnwrap(viewModel.beginAttachment())
        viewModel.finishAttachment(id: id, data: nil)
        XCTAssertTrue(viewModel.attachments.isEmpty)
    }

    func testAttachmentsAreCapped() {
        let (viewModel, _) = makeViewModel(ScriptedAssistantService([]))
        for _ in 0..<AssistantViewModel.maxAttachments {
            XCTAssertNotNil(viewModel.beginAttachment())
        }
        XCTAssertFalse(viewModel.canAttachMore)
        XCTAssertNil(viewModel.beginAttachment())
        XCTAssertEqual(viewModel.attachments.count, AssistantViewModel.maxAttachments)
    }

    func testMultiplePhotosAreSentTogether() async throws {
        let service = ScriptedAssistantService([AssistantResponse(text: "Nice menu.", toolCalls: [])])
        let (viewModel, _) = makeViewModel(service)
        for byte in [UInt8(1), 2] {
            let id = try XCTUnwrap(viewModel.beginAttachment())
            viewModel.finishAttachment(id: id, data: Data([byte]))
        }
        await viewModel.send()

        XCTAssertTrue(viewModel.attachments.isEmpty, "composer cleared after sending")
        let sent = try XCTUnwrap(service.receivedTurns.first?.first)
        let images = sent.blocks.filter { if case .image = $0 { return true }; return false }
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(viewModel.messages.contains {
            if case .user(_, let photos) = $0.kind { return photos.count == 2 }
            return false
        })
    }

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
