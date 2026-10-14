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

    /// "I forgot, there was also an egg in it": the edit carries the whole
    /// component list, so the ingredients and totals change - not just the name.
    func testEditWithItemsReplacesIngredientsAndRecalculates() throws {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let add) = executor.execute(AssistantToolCall(
            id: "a", tool: .addFoodEntry, arguments: [
                "name": .string("Konjac with tomato"),
                "items": .array([
                    .object(["name": .string("konjac knots"), "grams": .number(150)]),
                    .object(["name": .string("tomatoes"), "grams": .number(120)])
                ])])) else { return XCTFail("expected an add proposal") }
        try executor.commit(add)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<FoodEntry>()).first)
        let before = entry.total.calories
        let konjacID = try XCTUnwrap(entry.orderedIngredients.first { $0.name == "konjac knots" }?.id)

        guard case .awaitingConfirmation(let edit) = executor.execute(AssistantToolCall(
            id: "e", tool: .editFoodEntry, arguments: [
                "id": .string(entry.id.uuidString),
                "name": .string("Konjac with tomato and egg"),
                "items": .array([
                    .object(["name": .string("konjac knots"), "grams": .number(150)]),
                    .object(["name": .string("tomatoes"), "grams": .number(120)]),
                    .object(["name": .string("egg"), "grams": .number(50)])
                ])])) else { return XCTFail("expected an edit proposal") }
        guard case .edit(_, let draft, _) = edit.action else { return XCTFail() }
        XCTAssertEqual(draft.ingredients.count, 3, "the card shows the egg before saving")

        try executor.commit(edit)
        XCTAssertEqual(count(context), 1, "edited, not added as a second entry")
        XCTAssertEqual(entry.name, "Konjac with tomato and egg")
        XCTAssertEqual(entry.orderedIngredients.map(\.name), ["konjac knots", "tomatoes", "egg"])
        XCTAssertGreaterThan(entry.total.calories, before + 50, "the egg's calories are counted")
        XCTAssertTrue(entry.orderedIngredients.contains { $0.id == konjacID },
                      "unchanged ingredients are kept, not recreated")
    }

    /// Figures from a nutrition label (typed, photographed or the brand's own)
    /// win over the app's database, which would otherwise replace them.
    func testLabelFiguresBeatTheDatabase() throws {
        let executor = AssistantToolExecutor(context: TestSupport.makeContext())
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "l", tool: .addFoodEntry, arguments: [
                "name": .string("Konjac noodles"),
                "items": .array([
                    .object(["name": .string("konjac knots"), "grams": .number(200),
                             "kcalPer100g": .number(9), "carbsPer100g": .number(3),
                             "proteinPer100g": .number(0.2), "fatPer100g": .number(0.1),
                             "nutritionSource": .string("label")]),
                    .object(["name": .string("Farm Fresh fresh milk"), "grams": .number(250),
                             "kcalPer100g": .number(64), "proteinPer100g": .number(3.2),
                             "fatPer100g": .number(3.5), "carbsPer100g": .number(4.8),
                             "nutritionSource": .string("brand")])
                ])])),
              case .add(let draft) = write.action else { return XCTFail("expected an add proposal") }

        let konjac = try XCTUnwrap(draft.ingredients.first)
        XCTAssertEqual(konjac.provenance, .nutritionLabel)
        XCTAssertEqual(konjac.nutritionPerServing.calories, 9, "kept, not replaced by gen.konjac")
        XCTAssertNil(konjac.canonicalID)
        let milk = try XCTUnwrap(draft.ingredients.last)
        XCTAssertEqual(milk.provenance, .brandPublished)
        XCTAssertEqual(milk.total.calories, 160, accuracy: 0.5)
    }

    func testDeclaredFiguresAreNotRepairedLikeGuesses() throws {
        // A label's kcal can legitimately differ from 4/4/9 (polyols, alcohol);
        // a guess that far off would be corrected.
        let label = try XCTUnwrap(AssistantArgumentParser.parseItem([
            "name": .string("sugar-free sweet"), "grams": .number(20),
            "kcalPer100g": .number(240), "carbsPer100g": .number(95),
            "nutritionSource": .string("label")]))
        XCTAssertEqual(label.nutritionPerServing.calories, 240)

        let empty = try XCTUnwrap(AssistantArgumentParser.parseItem([
            "name": .string("milk"), "grams": .number(250),
            "nutritionSource": .string("label")]))
        XCTAssertEqual(empty.provenance, .modelEstimate, "a label with no figures is a guess")
    }

    /// "I only ate half": the dish's servings are halved and its ingredients
    /// stay as they are.
    func testHalfPortionEditHalvesTheServings() throws {
        let context = TestSupport.makeContext()
        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let add) = executor.execute(AssistantToolCall(
            id: "a", tool: .addFoodEntry, arguments: [
                "name": .string("Nasi lemak"),
                "items": .array([
                    .object(["name": .string("rice"), "grams": .number(200)]),
                    .object(["name": .string("egg"), "grams": .number(50)])
                ])])) else { return XCTFail() }
        try executor.commit(add)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<FoodEntry>()).first)
        let full = entry.total.calories

        guard case .awaitingConfirmation(let edit) = executor.execute(AssistantToolCall(
            id: "e", tool: .editFoodEntry,
            arguments: ["id": .string(entry.id.uuidString), "quantity": .number(0.5)])) else {
            return XCTFail()
        }
        try executor.commit(edit)
        XCTAssertEqual(entry.quantity, 0.5)
        XCTAssertEqual(entry.orderedIngredients.count, 2)
        XCTAssertEqual(entry.total.calories, full / 2, accuracy: 0.5)
    }

    func testKnownIngredientsKeepHandEditedFigures() {
        var draft = FoodEntryDraft(name: "Bowl")
        draft.ingredients = [IngredientDraft(name: "Rice", quantity: 150, servingSize: 100,
                                             nutritionPerServing: Nutrition(calories: 111))]
        let merged = AssistantToolExecutor.keepingKnownFigures(
            [IngredientDraft(name: "rice", quantity: 200, servingSize: 100,
                             nutritionPerServing: Nutrition(calories: 130)),
             IngredientDraft(name: "egg", quantity: 50, servingSize: 100)],
            from: draft)
        XCTAssertEqual(merged.first?.id, draft.ingredients.first?.id)
        XCTAssertEqual(merged.first?.quantity, 200, "new amount")
        XCTAssertEqual(merged.first?.nutritionPerServing.calories, 111, "own figures kept")
        XCTAssertEqual(merged.last?.name, "egg")
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

    /// Just after midnight the model sees the local clock and last night's
    /// entries, so "before midnight" lands on yesterday.
    func testSmallHoursIncludeLocalTimeAndYesterday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        let context = TestSupport.makeContext()
        context.insert(TestSupport.entry(name: "Dinner",
                                         at: TestSupport.date(2026, 10, 13, 20, calendar: calendar)))
        try context.save()
        let builder = AssistantContextBuilder(context: context, calendar: calendar)

        let lateNight = builder.build(now: TestSupport.date(2026, 10, 14, 0, 30, calendar: calendar))
        XCTAssertTrue(lateNight.localTime.hasPrefix("00:30"))
        XCTAssertEqual(lateNight.localDate, "2026-10-14")
        XCTAssertTrue(lateNight.entriesToday.isEmpty)
        XCTAssertEqual(lateNight.entriesYesterday?.map(\.name), ["Dinner"])

        let afternoon = builder.build(now: TestSupport.date(2026, 10, 14, 15, calendar: calendar))
        XCTAssertNil(afternoon.entriesYesterday, "only in the small hours")
    }

    func testLocalTimesWithoutAnOffsetAreReadAsLocal() throws {
        let kualaLumpur = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kualaLumpur
        let expected = TestSupport.date(2026, 10, 13, 23, 45, calendar: calendar)
        XCTAssertEqual(AssistantArgumentParser.parseDate(.string("2026-10-13T23:45"),
                                                         timeZone: kualaLumpur), expected)
        XCTAssertEqual(AssistantArgumentParser.parseDate(.string("2026-10-13T23:45:00+08:00")),
                       expected)
        XCTAssertEqual(AssistantArgumentParser.parseDate(.string("2026-10-13 23:45"),
                                                         timeZone: kualaLumpur), expected)
    }

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

    /// Nil means search isn't available, like a non-Gemini provider.
    var searchResult: WebSearchResult?
    private(set) var searchQuestions: [String] = []

    func searchWeb(_ question: String) async throws -> WebSearchResult {
        searchQuestions.append(question)
        guard let searchResult else {
            throw AssistantServiceError.requestFailed(detail: "web search isn't available")
        }
        return searchResult
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

    /// Replies appear a few words at a time, but the stored message is always
    /// the whole reply.
    func testReplyIsRevealedGraduallyThenShownWhole() async throws {
        let reply = "Have **two sticks** of satay and a small bowl of rice."
        let (viewModel, _) = makeViewModel(ScriptedAssistantService([
            AssistantResponse(text: reply, toolCalls: [])]))
        viewModel.composerText = "what should I eat?"
        await viewModel.send()

        let message = try XCTUnwrap(viewModel.messages.last)
        XCTAssertEqual(message.kind, .assistant(reply), "full text saved straight away")
        XCTAssertEqual(viewModel.revealingMessageID, message.id)
        XCTAssertLessThan(viewModel.displayedText(reply, for: message.id).count, reply.count)

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(viewModel.revealingMessageID)
        XCTAssertEqual(viewModel.displayedText(reply, for: message.id), reply)
    }

    /// "I'm in Mid Valley, what should I eat? RM15": the place and budget are
    /// searched, and the results go back to the model to recommend from.
    func testFindFoodNearbySearchesAndReturnsResultsToTheModel() async throws {
        let service = ScriptedAssistantService([
            AssistantResponse(text: nil, toolCalls: [AssistantToolCall(
                id: "s", tool: .findFoodNearby,
                arguments: ["place": .string("Mid Valley Megamall"), "budget": .string("RM15")])]),
            AssistantResponse(text: "Try the chicken rice at Stall A (RM12).", toolCalls: [])
        ])
        service.searchResult = WebSearchResult(
            summary: "Stall A, LG floor: chicken rice RM12.",
            sources: [.init(title: "Mall directory", url: "https://example.com")])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "I'm in Mid Valley, what should I eat? Budget RM15"
        await viewModel.send()

        let question = try XCTUnwrap(service.searchQuestions.first)
        XCTAssertTrue(question.contains("Mid Valley Megamall"))
        XCTAssertTrue(question.contains("Budget: RM15"))
        let sent = try XCTUnwrap(service.receivedTurns.last).flatMap(\.blocks)
        XCTAssertTrue(sent.contains {
            if case .toolResult("s", let content, false) = $0 { return content.contains("chicken rice RM12") }
            return false
        })
        XCTAssertEqual(viewModel.messages.last?.kind, .assistant("Try the chicken rice at Stall A (RM12)."))
    }

    func testFailedSearchIsReportedToTheModelNotTheUser() async throws {
        let service = ScriptedAssistantService([
            AssistantResponse(text: nil, toolCalls: [AssistantToolCall(
                id: "s", tool: .findFoodNearby, arguments: ["place": .string("Pavilion")])]),
            AssistantResponse(text: "I couldn't search just now.", toolCalls: [])
        ])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "what's good at Pavilion?"
        await viewModel.send()

        let sent = try XCTUnwrap(service.receivedTurns.last).flatMap(\.blocks)
        XCTAssertTrue(sent.contains {
            if case .toolResult("s", _, true) = $0 { return true }
            return false
        })
        XCTAssertFalse(viewModel.messages.contains {
            if case .error = $0.kind { return true }
            return false
        })
    }

    func testRevealStopsAtWordEnds() {
        XCTAssertEqual(AssistantViewModel.revealStops(in: "Hi there  you"), [2, 8, 13])
        XCTAssertEqual(AssistantViewModel.revealStops(in: "Done. "), [5, 6])
        XCTAssertEqual(AssistantViewModel.revealStops(in: ""), [0])
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
        var arguments = AssistantToolExecutorTests.tinyArguments
        arguments["replacesCard"] = .string("toolu_add")
        let amended = AssistantResponse(text: nil, toolCalls: [
            AssistantToolCall(id: "toolu_add2", tool: .addFoodEntry, arguments: arguments)])
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

    // MARK: Several cards

    private func dish(_ id: String, _ name: String, grams: Double = 200) -> AssistantToolCall {
        AssistantToolCall(id: id, tool: .addFoodEntry, arguments: [
            "name": .string(name),
            "items": .array([.object(["name": .string(name.lowercased()), "grams": .number(grams),
                                      "kcalPer100g": .number(100)])])])
    }

    private var japaneseSet: AssistantResponse {
        AssistantResponse(text: nil, toolCalls: [dish("miso", "Miso soup"),
                                                 dish("chawan", "Chawanmushi", grams: 120),
                                                 dish("don", "Salmon don", grams: 350)])
    }

    /// A photo of three bowls becomes three cards, each handled on its own.
    func testEachDishGetsItsOwnCard() async throws {
        let service = ScriptedAssistantService([japaneseSet])
        let (viewModel, context) = makeViewModel(service)
        viewModel.composerText = "I had this set"
        await viewModel.send()

        XCTAssertEqual(viewModel.pendingWrites.map(\.id), ["miso", "chawan", "don"])
        XCTAssertEqual(viewModel.confirmableTogether.count, 3)

        let chawanmushi = try XCTUnwrap(viewModel.pendingWrites.first { $0.id == "chawan" })
        await viewModel.confirm(chawanmushi)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 1)
        XCTAssertEqual(viewModel.pendingWrites.map(\.id), ["miso", "don"], "the others stay open")

        let miso = try XCTUnwrap(viewModel.pendingWrites.first)
        await viewModel.decline(miso)
        await viewModel.confirmAllAdditions()
        XCTAssertTrue(viewModel.pendingWrites.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 2)

        // Every card's outcome goes back together, once all are answered.
        viewModel.composerText = "thanks"
        await viewModel.send()
        let request = try XCTUnwrap(service.receivedTurns.last)
        let results = toolResults(in: request)
        XCTAssertEqual(Set(results.map(\.id)), ["miso", "chawan", "don"])
        XCTAssertTrue(results.contains { $0.id == "miso" && $0.content.contains("declined") })
    }

    /// "I actually had 3 chawanmushi": only that card is replaced.
    func testAmendingOneCardLeavesTheOthersOpen() async throws {
        var amended = dish("chawan2", "Chawanmushi", grams: 360)
        amended = AssistantToolCall(id: amended.id, tool: amended.tool,
                                    arguments: amended.arguments.merging(
                                        ["replacesCard": .string("chawan")]) { $1 })
        let service = ScriptedAssistantService([
            japaneseSet, AssistantResponse(text: nil, toolCalls: [amended])])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "I had this set"
        await viewModel.send()
        viewModel.composerText = "I had 3 chawanmushi"
        await viewModel.send()

        // The model heard all three cards were waiting, with ids to amend by.
        let request = try XCTUnwrap(service.receivedTurns.last)
        let waiting = toolResults(in: request).filter { $0.content.contains("awaiting_user") }
        XCTAssertEqual(Set(waiting.map(\.id)), ["miso", "chawan", "don"])
        XCTAssertTrue(waiting.contains { $0.content.contains("\"cardID\":\"chawan\"") })

        XCTAssertEqual(viewModel.pendingWrites.map(\.id), ["miso", "don", "chawan2"])
        XCTAssertEqual(viewModel.replacedWriteIDs, ["chawan"])
    }

    /// Adding another dish to the meal doesn't close the cards already open.
    func testANewDishDoesNotReplaceOpenCards() async throws {
        let service = ScriptedAssistantService([
            AssistantResponse(text: nil, toolCalls: [dish("miso", "Miso soup")]),
            AssistantResponse(text: nil, toolCalls: [dish("tea", "Green tea")])])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "miso soup"
        await viewModel.send()
        viewModel.composerText = "and a green tea"
        await viewModel.send()

        XCTAssertEqual(viewModel.pendingWrites.map(\.id), ["miso", "tea"])
        XCTAssertTrue(viewModel.replacedWriteIDs.isEmpty)
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

// MARK: - Web search

final class AssistantWebSearchTests: XCTestCase {

    func testSearchResponseGivesTextAndUniqueSources() throws {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"Stall A: chicken rice RM12. "},{"text":"Stall B: soup RM10."}]},
          "groundingMetadata":{"groundingChunks":[
            {"web":{"uri":"https://a.example","title":"A"}},
            {"web":{"uri":"https://a.example","title":"A again"}},
            {"web":{"uri":"https://b.example"}}]}}]}
        """
        let result = try OpenAICompatibleAssistantService.decodeSearch(data: Data(json.utf8))
        XCTAssertEqual(result.summary, "Stall A: chicken rice RM12. Stall B: soup RM10.")
        XCTAssertEqual(result.sources.map(\.url), ["https://a.example", "https://b.example"])
        XCTAssertEqual(result.sources.last?.title, "https://b.example", "falls back to the link")
    }

    func testEmptySearchResponseThrows() {
        XCTAssertThrowsError(try OpenAICompatibleAssistantService.decodeSearch(
            data: Data(#"{"candidates":[{"content":{"parts":[]}}]}"#.utf8)))
    }

    func testSearchUsesGeminisOwnAPI() {
        let gemini = OpenAICompatibleAssistantService(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/", pinnedModel: nil)
        XCTAssertEqual(gemini.nativeGeminiRoot, "https://generativelanguage.googleapis.com/v1beta")
        let other = OpenAICompatibleAssistantService(baseURL: "https://api.deepseek.com", pinnedModel: nil)
        XCTAssertNil(other.nativeGeminiRoot, "no search on other providers")
    }

    @MainActor
    func testBrandLookupAsksForPer100gFactsOfThatProduct() {
        let (question, activity) = AssistantViewModel.webQuestion(for: AssistantToolCall(
            id: "p", tool: .lookUpProductNutrition,
            arguments: ["product": .string("Farm Fresh fresh milk"), "country": .string("Malaysia")]))
        XCTAssertTrue(question.contains("Farm Fresh fresh milk"))
        XCTAssertTrue(question.contains("per 100 g"))
        XCTAssertTrue(question.contains("Malaysia"))
        XCTAssertEqual(activity, "Looked up nutrition for Farm Fresh fresh milk")
        XCTAssertTrue(AssistantTool.lookUpProductNutrition.usesWebSearch)
        XCTAssertFalse(AssistantTool.lookUpProductNutrition.isWrite)
    }

    @MainActor
    func testQuestionOnlyMentionsBudgetWhenGiven() {
        let withBudget = AssistantViewModel.nearbyFoodQuestion(
            place: "Mid Valley", budget: "RM15", preferences: "high protein")
        XCTAssertTrue(withBudget.contains("Mid Valley"))
        XCTAssertTrue(withBudget.contains("Budget: RM15"))
        XCTAssertTrue(withBudget.contains("Prefer: high protein"))
        let without = AssistantViewModel.nearbyFoodQuestion(place: "Mid Valley", budget: " ",
                                                            preferences: nil)
        XCTAssertFalse(without.contains("Budget"))
    }
}

// MARK: - Chat scrolling

@MainActor
final class ChatBottomEdgeTests: XCTestCase {

    /// At the very end the visible area runs past the content by the bottom
    /// inset (the tab bar), which must still count as "at the bottom".
    func testScrolledToTheEndIsAtTheBottom() {
        XCTAssertTrue(BottomEdgeTracker.isAtBottom(visibleMaxY: 1083, contentHeight: 1000,
                                                   bottomInset: 83))
        XCTAssertTrue(BottomEdgeTracker.isAtBottom(visibleMaxY: 1060, contentHeight: 1000,
                                                   bottomInset: 83), "within the tolerance")
    }

    func testScrolledUpIsNotAtTheBottom() {
        XCTAssertFalse(BottomEdgeTracker.isAtBottom(visibleMaxY: 983, contentHeight: 1000,
                                                    bottomInset: 83),
                       "100 pt up is away from the bottom, even though the tab bar is 83 pt")
    }

    func testShortChatIsAtTheBottom() {
        XCTAssertTrue(BottomEdgeTracker.isAtBottom(visibleMaxY: 700, contentHeight: 300,
                                                   bottomInset: 83))
    }

    /// A short chat has nothing to scroll, so a growing reply never moves it.
    func testShortChatDoesNotOverflow() {
        XCTAssertFalse(BottomEdgeTracker.overflows(contentHeight: 300, containerHeight: 700,
                                                   topInset: 0, bottomInset: 83))
        XCTAssertTrue(BottomEdgeTracker.overflows(contentHeight: 680, containerHeight: 700,
                                                  topInset: 0, bottomInset: 83),
                      "taller than the space above the tab bar")
    }
}

// MARK: - Safeguards against the model's mistakes

@MainActor
final class AssistantSafeguardTests: XCTestCase {

    private func makeViewModel(_ service: ScriptedAssistantService) -> (AssistantViewModel, ModelContext) {
        let context = TestSupport.makeContext()
        return (AssistantViewModel(service: service,
                                   executor: AssistantToolExecutor(context: context),
                                   contextBuilder: AssistantContextBuilder(context: context)),
                context)
    }

    private func food(_ name: String, grams: JSONValue = .number(100),
                      extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["name": .string(name),
                 "items": .array([.object(["name": .string(name.lowercased()), "grams": grams,
                                           "kcalPer100g": .number(100)])])]
                .merging(extra) { $1 })
    }

    /// "A banana, a yoghurt and a shake" in one call still makes one card each.
    func testFoodsListMakesOneCardPerFood() async throws {
        let service = ScriptedAssistantService([AssistantResponse(text: nil, toolCalls: [
            AssistantToolCall(id: "c", tool: .addFoodEntry, arguments: [
                "foods": .array([food("Banana"), food("Greek yoghurt"), food("Protein shake")])])
        ])])
        let (viewModel, context) = makeViewModel(service)
        viewModel.composerText = "banana, yoghurt and a shake"
        await viewModel.send()
        XCTAssertEqual(viewModel.pendingWrites.map(\.id), ["c#1", "c#2", "c#3"])

        await viewModel.confirmAllAdditions()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodEntry>()), 3)

        // The model gets one result for its one call, covering all three cards.
        viewModel.composerText = "thanks"
        await viewModel.send()
        let ids = (service.receivedTurns.last ?? []).flatMap(\.blocks).compactMap { block -> String? in
            if case .toolResult(let id, _, _) = block { return id }
            return nil
        }
        XCTAssertEqual(ids, ["c"])
    }

    /// One bad item used to be dropped and the rest logged - the shake vanished.
    func testABadItemRejectsTheCardInsteadOfVanishing() {
        let executor = AssistantToolExecutor(context: TestSupport.makeContext())
        let outcome = executor.execute(AssistantToolCall(id: "a", tool: .addFoodEntry, arguments: [
            "name": .string("Snack"),
            "items": .array([
                .object(["name": .string("banana"), "grams": .number(118)]),
                .object(["name": .string("whey isolate"), "servings": .number(1)])
            ])]))
        guard case .failure(let message) = outcome else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("whey isolate"))
    }

    func testGramsWithUnitsAreRead() {
        XCTAssertEqual(JSONValue.string("250 g").doubleValue, 250)
        XCTAssertEqual(JSONValue.string("~30g").doubleValue, 30)
        XCTAssertNil(JSONValue.string("one cup").doubleValue)
    }

    /// No database match and no figures would log 0 kcal; the model is asked again.
    func testItemsWithNoNutritionAreSentBack() {
        let executor = AssistantToolExecutor(context: TestSupport.makeContext())
        let outcome = executor.execute(AssistantToolCall(id: "a", tool: .addFoodEntry, arguments: [
            "name": .string("Mystery"),
            "items": .array([.object(["name": .string("zorbleberry"), "grams": .number(100)])])]))
        guard case .failure(let message) = outcome else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("zorbleberry"))
    }

    /// Label figures with protein missing (shown as 0 g) are a misread label.
    func testIncompleteLabelFiguresAreSentBack() {
        XCTAssertThrowsError(try AssistantToolExecutor.checkLabelFigures(.array([.object([
            "name": .string("chicken breast"), "kcalPer100g": .number(118),
            "carbsPer100g": .number(2), "fatPer100g": .number(3),
            "nutritionSource": .string("label")])]), tool: .addFoodEntry))
    }

    func testLookedUpProductMustUseItsFigures() {
        let detail = AssistantViewModel.unusedBrandFigures(
            in: ["foods": .array([food("Optimum Nutrition whey isolate")])],
            lookedUp: ["Optimum Nutrition Gold Standard 100% Isolate"])
        XCTAssertNotNil(detail)
        XCTAssertNil(AssistantViewModel.unusedBrandFigures(
            in: ["foods": .array([food("Optimum Nutrition whey isolate",
                                       extra: [:])])],
            lookedUp: []), "nothing looked up, nothing to enforce")
    }

    /// Correcting the brand of last night's shake keeps last night's time.
    func testAmendedCardWithoutATimeKeepsTheOldTime() {
        let lastNight = Date.now.addingTimeInterval(-3 * 3600)
        let old = PendingAssistantWrite(id: "a", tool: .addFoodEntry,
                                        action: .add(FoodEntryDraft(name: "Shake", consumedAt: lastNight)))
        let new = PendingAssistantWrite(id: "b", tool: .addFoodEntry,
                                        action: .add(FoodEntryDraft(name: "Shake")))
        guard case .add(let draft) = AssistantViewModel.retimed(new, like: old).action else {
            return XCTFail()
        }
        XCTAssertEqual(draft.consumedAt, lastNight)
    }

    /// Editing an unconfirmed card by its card id steers the model instead of
    /// showing "not a valid entry identifier".
    func testEditAimedAtAnUnsavedCardIsRedirected() async throws {
        let service = ScriptedAssistantService([
            AssistantResponse(text: nil, toolCalls: [AssistantToolCall(
                id: "card", tool: .addFoodEntry, arguments: ["foods": .array([food("Wrap")])])]),
            AssistantResponse(text: nil, toolCalls: [AssistantToolCall(
                id: "e", tool: .editFoodEntry, arguments: ["id": .string("card")])]),
            AssistantResponse(text: "Fixed.", toolCalls: [])
        ])
        let (viewModel, _) = makeViewModel(service)
        viewModel.composerText = "a wrap"
        await viewModel.send()
        viewModel.composerText = "why protein 0"
        await viewModel.send()

        XCTAssertFalse(viewModel.messages.contains {
            if case .error = $0.kind { return true }
            return false
        })
        let sent = (service.receivedTurns.last ?? []).flatMap(\.blocks)
        XCTAssertTrue(sent.contains {
            if case .toolResult("e", let content, true) = $0 { return content.contains("replacesCard") }
            return false
        })
    }
}
