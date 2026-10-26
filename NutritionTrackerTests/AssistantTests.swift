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

// MARK: - Provider response decoding (OpenAI Responses API)

final class AssistantResponseDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> AssistantResponse {
        try OpenAIAssistantService.decode(data: Data(json.utf8))
    }

    func testDecodesTextAndToolCall() throws {
        let response = try decode("""
        {"output": [
          {"type": "reasoning", "id": "rs_1", "summary": []},
          {"type": "message", "role": "assistant", "content": [
            {"type": "output_text", "text": "I can log that.", "annotations": []}]},
          {"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "addFoodEntry",
           "arguments": "{\\"name\\": \\"Nasi Lemak\\", \\"calories\\": 650, \\"quantity\\": 1}"}]}
        """)
        XCTAssertEqual(response.text, "I can log that.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].id, "call_1", "the call_id, not the item id")
        XCTAssertEqual(response.toolCalls[0].tool, .addFoodEntry)
        XCTAssertEqual(response.toolCalls[0].arguments["calories"], .number(650))
    }

    func testArgumentsAsObjectAreAccepted() throws {
        let response = try decode("""
        {"output": [{"type": "function_call", "call_id": "c", "name": "getTrends",
          "arguments": {"timeframe": "weekly"}}]}
        """)
        XCTAssertEqual(response.toolCalls.first?.arguments["timeframe"], .string("weekly"))
        XCTAssertNil(response.text)
    }

    func testHallucinatedToolNameIsDropped() throws {
        let response = try decode("""
        {"output": [
          {"type": "message", "content": [{"type": "output_text", "text": "Hmm."}]},
          {"type": "function_call", "call_id": "t", "name": "orderPizza", "arguments": "{}"}]}
        """)
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    func testMissingCallIdIsGenerated() throws {
        let response = try decode("""
        {"output": [{"type": "function_call", "name": "queryEntries", "arguments": "{}"}]}
        """)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertFalse(response.toolCalls[0].id.isEmpty)
    }

    func testMalformedArgumentsBecomeEmpty() throws {
        let response = try decode("""
        {"output": [{"type": "function_call", "call_id": "c", "name": "queryEntries",
          "arguments": "{not json"}]}
        """)
        XCTAssertEqual(response.toolCalls.first?.arguments, [:])
    }

    func testMalformedOrEmptyReplyThrows() {
        XCTAssertThrowsError(try decode("{\"nope\": 1}")) {
            guard case .malformedResponse = $0 as? AssistantServiceError else {
                return XCTFail("expected malformedResponse")
            }
        }
        // Only reasoning, no message or call: nothing to show.
        XCTAssertThrowsError(try decode(#"{"output": [{"type": "reasoning"}]}"#))
    }
}

final class AssistantProviderStatusTests: XCTestCase {

    func testDefaultsAreGPT6LunaAtLowEffort() {
        XCTAssertEqual(OpenAIAssistantService.defaultModel, "gpt-6-luna")
        XCTAssertEqual(OpenAIAssistantService.reasoningEffort, "low")
        XCTAssertEqual(OpenAIAssistantService.defaultBaseURL, "https://api.openai.com/v1")
    }

    func testStatusMapping() {
        XCTAssertThrowsError(try OpenAIAssistantService.check(status: 404, model: "m")) {
            XCTAssertEqual($0 as? AssistantServiceError, .modelUnavailable(model: "m"))
        }
        XCTAssertThrowsError(try OpenAIAssistantService.check(status: 429, model: "m")) {
            XCTAssertEqual($0 as? AssistantServiceError, .rateLimited)
        }
        XCTAssertThrowsError(try OpenAIAssistantService.check(status: 503, model: "m")) {
            XCTAssertEqual($0 as? AssistantServiceError, .providerBusy(status: 503))
        }
        XCTAssertNoThrow(try OpenAIAssistantService.check(status: 200, model: "m"))
    }

    /// Overloaded-server responses are retried; client errors are not.
    func testOnlyServerOverloadIsRetried() {
        for status in [500, 502, 503, 504] {
            XCTAssertTrue(OpenAIAssistantService.isTransient(status), "\(status)")
        }
        for status in [200, 400, 401, 404, 429] {
            XCTAssertFalse(OpenAIAssistantService.isTransient(status), "\(status)")
        }
    }

    func testProviderErrorMessageIsExtractedAndShort() {
        let body = Data(#"{"error": {"type": "invalid_request_error", "message": "Incorrect API key provided.\nMore detail here."}}"#.utf8)
        XCTAssertEqual(OpenAIAssistantService.providerErrorMessage(from: body),
                       "Incorrect API key provided.")
        XCTAssertNil(OpenAIAssistantService.providerErrorMessage(from: Data("oops".utf8)))
        XCTAssertThrowsError(try OpenAIAssistantService.check(status: 401, model: "m", body: body)) {
            XCTAssertEqual($0 as? AssistantServiceError,
                           .requestFailed(detail: "HTTP 401 - Incorrect API key provided."))
        }
    }
}

final class AssistantRequestEncodingTests: XCTestCase {

    func testToolResultsBecomeFunctionCallOutputs() {
        let turn = AssistantTurn(role: .user, blocks: [
            .toolResult(id: "a", content: "{\"x\":1}", isError: false),
            .toolResult(id: "b", content: "{\"y\":2}", isError: false)
        ])
        let items = OpenAIAssistantService.encode(turn: turn)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["type"] as? String, "function_call_output")
        XCTAssertEqual(items[0]["call_id"] as? String, "a")
        XCTAssertEqual(items[0]["output"] as? String, "{\"x\":1}")
        XCTAssertEqual(items[1]["call_id"] as? String, "b")
    }

    /// Text first, then each call as its own item with JSON-string arguments
    /// and no item id (an id would require the matching reasoning item).
    func testAssistantToolCallsBecomeFunctionCallItems() throws {
        let turn = AssistantTurn(role: .assistant, blocks: [
            .text("Logging it."),
            .toolUse(id: "c1", name: "addFoodEntry", input: ["name": .string("Teh Tarik")])
        ])
        let items = OpenAIAssistantService.encode(turn: turn)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["role"] as? String, "assistant")
        XCTAssertEqual(items[0]["content"] as? String, "Logging it.")
        XCTAssertEqual(items[1]["type"] as? String, "function_call")
        XCTAssertEqual(items[1]["call_id"] as? String, "c1")
        XCTAssertNil(items[1]["id"])
        let arguments = try XCTUnwrap(items[1]["arguments"] as? String)
        XCTAssertTrue(arguments.contains("Teh Tarik"))
    }

    func testACountSentAsGramsIsRejected() throws {
        // "1 cup" of gelato sent with grams 1 logged 3 kcal.
        let count: JSONValue = .array([.object([
            "name": .string("Vegan tofu gelato (1 cup)"), "grams": .number(1),
            "kcalPer100g": .number(150)])])
        XCTAssertThrowsError(try AssistantArgumentParser.checkItems(count, tool: .addFoodEntry))

        let weight: JSONValue = .array([.object([
            "name": .string("Vegan tofu gelato (1 cup)"), "grams": .number(90),
            "kcalPer100g": .number(150)])])
        XCTAssertNoThrow(try AssistantArgumentParser.checkItems(weight, tool: .addFoodEntry))

        // A pinch of salt really is a gram or two.
        let salt: JSONValue = .array([.object(["name": .string("Salt"), "grams": .number(1)])])
        XCTAssertNoThrow(try AssistantArgumentParser.checkItems(salt, tool: .addFoodEntry))
    }

    func testPDFBecomesInputFileAndTextFileBecomesInputText() throws {
        let turn = AssistantTurn(role: .user, blocks: [
            .file(name: "checkup.pdf", data: Data([1, 2, 3])),
            .file(name: "notes.txt", data: Data("HbA1c 6.3%".utf8)),
            .text("Read these")])
        let items = OpenAIAssistantService.encode(turn: turn)
        let parts = try XCTUnwrap(items.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "input_file")
        XCTAssertEqual(parts[0]["filename"] as? String, "checkup.pdf")
        XCTAssertTrue((parts[0]["file_data"] as? String)?
            .hasPrefix("data:application/pdf;base64,") == true)
        XCTAssertEqual(parts[1]["type"] as? String, "input_text")
        XCTAssertEqual(parts[1]["text"] as? String, "[Attached file: notes.txt]\nHbA1c 6.3%")
        XCTAssertEqual(parts[2]["text"] as? String, "Read these")
    }

    func testPhotoBecomesInputImage() throws {
        let turn = AssistantTurn(role: .user, blocks: [.image(Data([1, 2, 3])), .text("What fits?")])
        let items = OpenAIAssistantService.encode(turn: turn)
        let parts = try XCTUnwrap(items.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "input_image")
        XCTAssertTrue((parts.first?["image_url"] as? String)?
            .hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(parts.last?["type"] as? String, "input_text")
        XCTAssertEqual(parts.last?["text"] as? String, "What fits?")
    }

    func testBodyHasInstructionsToolsLowEffortAndNoStorage() throws {
        let body = OpenAIAssistantService.makeBody(
            model: "test-model", turns: [.user("hi")], contextJSON: "{\"k\":1}",
            tools: AssistantTool.allCases)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertTrue((body["instructions"] as? String)?.contains("{\"k\":1}") == true)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AssistantTool.allCases.count)
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertNotNil(tools.first?["name"], "Responses tools are flat, not nested")
        XCTAssertEqual(tools.first?["strict"] as? Bool, false)
    }

    func testSearchBodyUsesTheWebSearchTool() throws {
        let body = OpenAIAssistantService.makeSearchBody(model: "m", question: "Food near KLCC")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertEqual(body["input"] as? String, "Food near KLCC")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "web_search")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
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

    /// "The same overnight oats as on the 23rd": the log lists each
    /// ingredient with its grams and per-100 g figures, ready to copy.
    func testQueryEntriesListsIngredientsToRepeat() throws {
        let context = TestSupport.makeContext()
        let draft = FoodEntryDraft(name: "Overnight oats", ingredients: [
            IngredientDraft(name: "rolled oats", quantity: 40, servingSize: 100, unit: .gram,
                            nutritionPerServing: Nutrition(calories: 380, protein: 13,
                                                           carbs: 60, fat: 7, fibre: 10))
        ])
        context.insert(draft.makeEntry())
        try context.save()

        let outcome = AssistantToolExecutor(context: context)
            .execute(AssistantToolCall(id: "q", tool: .queryEntries, arguments: [:]))
        guard case .result(let json) = outcome else { return XCTFail() }
        XCTAssertTrue(json.contains("rolled oats"))
        XCTAssertTrue(json.contains("\"grams\":40"))
        XCTAssertTrue(json.contains("\"kcalPer100g\":380"))
        XCTAssertTrue(json.contains("\"nutritionSource\":\"saved\""))
    }

    /// Repeating an entry copies every ingredient, portion and figure into a
    /// separate new entry at the new time; the original is untouched.
    func testRepeatCopiesTheWholeEntry() throws {
        let context = TestSupport.makeContext()
        let original = FoodEntryDraft(name: "Overnight oats", consumedAt: .now.addingTimeInterval(-86_400),
                                      ingredients: [
            IngredientDraft(name: "rolled oats", quantity: 40, servingSize: 100, unit: .gram,
                            nutritionPerServing: Nutrition(calories: 380, protein: 13, carbs: 60, fat: 7)),
            IngredientDraft(name: "chocolate whey", quantity: 31, servingSize: 100, unit: .gram,
                            nutritionPerServing: Nutrition(calories: 374, protein: 77, carbs: 10, fat: 3))
        ]).makeEntry()
        context.insert(original)
        try context.save()

        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "r", tool: .repeatFoodEntry, arguments: ["id": .string(original.id.uuidString)]))
        else { return XCTFail("expected a card") }
        _ = try executor.commit(write)

        let entries = try context.fetch(FetchDescriptor<FoodEntry>())
        XCTAssertEqual(entries.count, 2)
        let copy = try XCTUnwrap(entries.first { $0.id != original.id })
        XCTAssertEqual(copy.name, "Overnight oats")
        XCTAssertEqual(copy.orderedIngredients.map(\.name), ["rolled oats", "chocolate whey"])
        XCTAssertEqual(copy.orderedIngredients.map(\.quantity), [40, 31])
        XCTAssertEqual(copy.total.calories, original.total.calories, accuracy: 0.001)
        XCTAssertTrue(LocalDay.isToday(copy.consumedAt), "logged now, not on the original day")
        XCTAssertEqual(original.orderedIngredients.count, 2, "the original keeps its ingredients")
    }

    func testRepeatOfAMissingEntryFails() {
        let outcome = AssistantToolExecutor(context: TestSupport.makeContext()).execute(
            AssistantToolCall(id: "r", tool: .repeatFoodEntry,
                              arguments: ["id": .string(UUID().uuidString)]))
        guard case .failure = outcome else { return XCTFail("expected failure") }
    }

    /// The same date as start and end reads that whole day, as people mean it.
    func testQueryEndDateIsInclusive() throws {
        let context = TestSupport.makeContext()
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: .now))!
        context.insert(TestSupport.entry(name: "Overnight oats",
                                         at: day.addingTimeInterval(8 * 3600), calories: 420))
        try context.save()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: day)

        let outcome = AssistantToolExecutor(context: context).execute(AssistantToolCall(
            id: "q", tool: .queryEntries,
            arguments: ["startDate": .string(date), "endDate": .string(date)]))
        guard case .result(let json) = outcome else { return XCTFail("expected a result") }
        XCTAssertTrue(json.contains("Overnight oats"))
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
    /// Target weight is sent now that the assistant can update the profile.
    func testPayloadOmitsUnneededPersonalDetail() throws {
        let context = TestSupport.makeContext()
        context.insert(UserProfile(dateOfBirth: TestSupport.date(1990, 1, 1), sex: .female,
                                   heightCm: 165, weightKg: 60, targetWeightKg: 55,
                                   goal: .loseWeight, activity: .light, bodyFatPercent: 28))
        try context.save()

        let json = try AssistantContextBuilder(context: context, healthNotes: { [] }).encodedJSON()
        XCTAssertFalse(json.contains("dateOfBirth"))
        XCTAssertFalse(json.contains("bodyFat"))
        XCTAssertTrue(json.contains("\"targetWeightKg\":55"))
        XCTAssertFalse(json.lowercased().contains("photo"))
    }

    /// Health notes and the last few days' food - dishes with what was in
    /// them - go to the assistant, for warnings like "a lot of prawns yesterday".
    func testContextCarriesHealthNotesAndRecentDays() throws {
        let context = TestSupport.makeContext()
        let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: .now)!
        context.insert(FoodEntryDraft(name: "Prawn mee", consumedAt: yesterday, ingredients: [
            IngredientDraft(name: "prawns", quantity: 250, servingSize: 100, unit: .gram,
                            nutritionPerServing: Nutrition(calories: 99, protein: 24)),
            IngredientDraft(name: "yellow noodles", quantity: 150, servingSize: 100, unit: .gram,
                            nutritionPerServing: Nutrition(calories: 140, carbs: 28))
        ]).makeEntry())
        try context.save()

        let note = HealthNote(condition: "High uric acid", details: "Uric acid 480 umol/L",
                              guidance: ["Limit prawns and other shellfish"])
        let json = try AssistantContextBuilder(context: context, healthNotes: { [note] })
            .encodedJSON()
        XCTAssertTrue(json.contains("High uric acid"))
        XCTAssertTrue(json.contains("Limit prawns and other shellfish"))
        XCTAssertTrue(json.contains("prawns 250 g"))
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

    /// The answer is the message text; sources are its url_citation
    /// annotations, de-duplicated, with the link standing in for a missing title.
    func testSearchResponseGivesTextAndUniqueSources() throws {
        let json = """
        {"output":[
          {"type":"web_search_call","id":"ws_1","status":"completed",
           "action":{"type":"search","query":"chicken rice near KLCC"}},
          {"type":"message","role":"assistant","content":[
            {"type":"output_text","text":"Stall A: chicken rice RM12. Stall B: soup RM10.",
             "annotations":[
               {"type":"url_citation","start_index":0,"end_index":5,"url":"https://a.example","title":"A"},
               {"type":"url_citation","start_index":6,"end_index":9,"url":"https://a.example","title":"A again"},
               {"type":"url_citation","start_index":10,"end_index":12,"url":"https://b.example","title":""}]}]}]}
        """
        let result = try OpenAIAssistantService.decodeSearch(data: Data(json.utf8))
        XCTAssertEqual(result.summary, "Stall A: chicken rice RM12. Stall B: soup RM10.")
        XCTAssertEqual(result.sources.map(\.url), ["https://a.example", "https://b.example"])
        XCTAssertEqual(result.sources.last?.title, "https://b.example", "falls back to the link")
    }

    func testEmptySearchResponseThrows() {
        XCTAssertThrowsError(try OpenAIAssistantService.decodeSearch(
            data: Data(#"{"output":[{"type":"web_search_call","status":"completed"}]}"#.utf8)))
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

    /// The products a blocked call sent as estimates, so the block can be
    /// lifted for them: it applies once, never in a loop.
    func testBlockedProductsAreIdentifiedForRelease() {
        let products = AssistantViewModel.productsSentAsEstimates(
            in: ["foods": .array([food("Kinori teriyaki chicken taco")])],
            lookedUp: ["Kinori Teriyaki Chicken sushi taco", "Farm Fresh milk"])
        XCTAssertEqual(products, ["Kinori Teriyaki Chicken sushi taco"])
    }

    /// Only a lookup that found real figures holds the product to them.
    func testLookupCountsOnlyWhenFiguresWereFound() {
        XCTAssertTrue(AssistantViewModel.foundPublishedFigures(
            in: "Per 100 g: 245 kcal, protein 12 g, carbs 30 g, fat 8 g."))
        XCTAssertFalse(AssistantViewModel.foundPublishedFigures(
            in: "NOT FOUND. Kinori doesn't publish nutrition information."))
        XCTAssertFalse(AssistantViewModel.foundPublishedFigures(
            in: "I couldn't find official nutrition facts for these tacos."))
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

// MARK: - Location, longer periods and quoted figures

private struct FixedLocator: CurrentLocating {
    var result: Result<CurrentPlace, CurrentLocationError>
    func currentPlace() async throws -> CurrentPlace { try result.get() }
}

@MainActor
final class AssistantReachTests: XCTestCase {

    private func makeViewModel(_ service: ScriptedAssistantService,
                               locator: CurrentLocating? = nil) -> AssistantViewModel {
        // Made here, not as a default argument: default values are evaluated
        // outside the main actor, where makeContext() can't be called.
        let context = TestSupport.makeContext()
        return AssistantViewModel(service: service,
                           executor: AssistantToolExecutor(context: context),
                           contextBuilder: AssistantContextBuilder(context: context),
                           locator: locator)
    }

    private func nearbyCall(_ arguments: [String: JSONValue] = [:]) -> AssistantResponse {
        AssistantResponse(text: nil, toolCalls: [AssistantToolCall(
            id: "n", tool: .findFoodNearby, arguments: arguments)])
    }

    /// "Somewhere to eat?" with no place searches where the user is, not a
    /// place from an example or earlier in the chat.
    func testNearbyWithoutAPlaceUsesTheCurrentLocation() async throws {
        let service = ScriptedAssistantService([nearbyCall(), AssistantResponse(text: "Try A.", toolCalls: [])])
        service.searchResult = WebSearchResult(summary: "A: nasi kerabu RM9.", sources: [])
        let here = CurrentPlace(name: "Bangsar, Kuala Lumpur", latitude: 3.1291, longitude: 101.6710)
        let viewModel = makeViewModel(service, locator: FixedLocator(result: .success(here)))
        viewModel.composerText = "what can I eat outside?"
        await viewModel.send()

        let question = try XCTUnwrap(service.searchQuestions.first)
        XCTAssertTrue(question.contains("Bangsar"))
        XCTAssertTrue(question.contains("3.1291"))
        XCTAssertTrue(question.contains("current location"))
        XCTAssertFalse(question.contains("Mid Valley"))
    }

    func testANamedAreaIsSearchedInstead() async throws {
        let service = ScriptedAssistantService([nearbyCall(["place": .string("SS15 Subang")]),
                                                AssistantResponse(text: "Ok.", toolCalls: [])])
        service.searchResult = WebSearchResult(summary: "B.", sources: [])
        let viewModel = makeViewModel(service, locator: FixedLocator(result: .failure(.denied)))
        viewModel.composerText = "food in SS15?"
        await viewModel.send()
        XCTAssertTrue(service.searchQuestions.first?.contains("SS15 Subang") == true)
    }

    func testNoLocationAccessMakesTheModelAskWhere() async throws {
        let service = ScriptedAssistantService([nearbyCall(["place": .string("near me")]),
                                                AssistantResponse(text: "Which area are you in?", toolCalls: [])])
        let viewModel = makeViewModel(service, locator: FixedLocator(result: .failure(.denied)))
        viewModel.composerText = "anything nearby?"
        await viewModel.send()

        XCTAssertTrue(service.searchQuestions.isEmpty, "nothing searched without a place")
        let sent = (service.receivedTurns.last ?? []).flatMap(\.blocks)
        XCTAssertTrue(sent.contains {
            if case .toolResult("n", let content, true) = $0 { return content.contains("which area") }
            return false
        })
    }

    /// The figures quoted in an answer come from the same calculation as the card.
    func testCalculatedFiguresMatchTheCard() throws {
        let executor = AssistantToolExecutor(context: TestSupport.makeContext())
        let food: [String: JSONValue] = [
            "name": .string("Egg fried rice"),
            "items": .array([.object(["name": .string("rice"), "grams": .number(200)]),
                             .object(["name": .string("egg"), "grams": .number(50)])])]
        guard case .result(let json) = executor.execute(AssistantToolCall(
            id: "c", tool: .calculateNutrition, arguments: ["foods": .array([.object(food)])])),
              case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "a", tool: .addFoodEntry, arguments: ["foods": .array([.object(food)])])),
              case .add(let draft) = write.action else { return XCTFail() }
        XCTAssertTrue(json.contains("\"calories\":\(Int(draft.total.calories.rounded()))"))
        XCTAssertTrue(json.contains("\"protein\":\(Int(draft.total.protein.rounded()))"))
    }

    /// Weekly views say how consistently each range was met, not just averages.
    func testWeeklyTrendsIncludeDayCountsAndWeekdayWeekend() throws {
        let context = TestSupport.makeContext()
        context.insert(NutritionTarget(ranges: TestSupport.ranges()))
        for daysAgo in 0..<10 {
            let date = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -daysAgo, to: .now)!
            context.insert(TestSupport.entry(at: date, calories: 1900, protein: 140))
        }
        try context.save()
        let executor = AssistantToolExecutor(context: context)
        guard case .result(let json) = executor.execute(AssistantToolCall(
            id: "t", tool: .getTrends,
            arguments: ["timeframe": .string("weekly"), "periods": .number(3)])) else {
            return XCTFail()
        }
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((payload["buckets"] as? [Any])?.count, 3, "three weeks, as asked")
        let summary = try XCTUnwrap(payload["summary"] as? [String: Any])
        XCTAssertEqual(summary["daysLogged"] as? Int, 10)
        XCTAssertNotNil(summary["dayStates"])
        XCTAssertNotNil(summary["weekdayAverage"])
    }

    func testNearMeDoesNotCountAsANamedPlace() {
        XCTAssertNil(AssistantViewModel.namedPlace(in: ["place": .string("Near me")]))
        XCTAssertNil(AssistantViewModel.namedPlace(in: [:]))
        XCTAssertEqual(AssistantViewModel.namedPlace(in: ["place": .string("Pavilion KL")]), "Pavilion KL")
    }
}

// MARK: - Empty chat

@MainActor
final class EmptyChatTests: XCTestCase {

    func testMomentFollowsTheTimeOfDay() {
        let calendar = TestSupport.calendar()
        func moment(_ hour: Int) -> EmptyChatView.Moment {
            .init(date: TestSupport.date(2026, 10, 20, hour, calendar: calendar), calendar: calendar)
        }
        XCTAssertEqual(moment(8), .breakfast)
        XCTAssertEqual(moment(12), .lunch)
        XCTAssertEqual(moment(16), .afternoon)
        XCTAssertEqual(moment(19), .dinner)
        XCTAssertEqual(moment(23), .lateNight)
        XCTAssertEqual(moment(3), .lateNight)
    }

    /// Every part of the day offers the menu photo and a way to log a meal.
    func testEveryMomentShowsWhatTheAssistantCanDo() {
        for moment in [EmptyChatView.Moment.breakfast, .lunch, .afternoon, .dinner, .lateNight] {
            XCTAssertTrue(moment.suggestions.contains { $0.action == .menuPhoto }, "\(moment)")
            XCTAssertTrue(moment.suggestions.contains {
                if case .draft = $0.action { return true } else { return false }
            }, "\(moment)")
        }
    }
}

// MARK: - Replies stay in their own chat

/// Holds each reply until the test releases it, so the test can switch chats
/// while a reply is still on its way.
final class GatedAssistantService: AssistantServing, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var callWaiter: CheckedContinuation<Void, Never>?
    private var wasCalled = false
    let reply: String

    init(reply: String) { self.reply = reply }

    var isConfigured: Bool { true }

    func send(turns: [AssistantTurn], contextJSON: String,
              tools: [AssistantTool]) async throws -> AssistantResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            gate = continuation
            wasCalled = true
            let waiter = callWaiter
            callWaiter = nil
            lock.unlock()
            waiter?.resume()
        }
        return AssistantResponse(text: reply, toolCalls: [])
    }

    /// Returns once a request is waiting at the gate.
    func waitUntilCalled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if wasCalled {
                lock.unlock()
                continuation.resume()
            } else {
                callWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        let waiting = gate
        gate = nil
        lock.unlock()
        waiting?.resume()
    }
}

@MainActor
final class ConversationIsolationTests: XCTestCase {

    /// Sending, then starting a new chat before the reply comes: the reply
    /// lands in the chat it was asked in, and the new chat stays empty.
    func testReplyArrivingAfterSwitchingStaysInItsChat() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = ChatHistoryStore(directory: directory)
        let context = TestSupport.makeContext()
        let service = GatedAssistantService(reply: "Logged your teh tarik.")
        let viewModel = AssistantViewModel(service: service,
                                           executor: AssistantToolExecutor(context: context),
                                           contextBuilder: AssistantContextBuilder(context: context),
                                           historyStore: store)

        viewModel.composerText = "I had a teh tarik"
        let sending = Task { await viewModel.send() }
        await service.waitUntilCalled()
        let firstChat = viewModel.conversationID

        viewModel.startNewConversation()
        XCTAssertNotEqual(viewModel.conversationID, firstChat)

        service.release()
        await sending.value

        XCTAssertTrue(viewModel.messages.isEmpty, "the new chat got nothing")
        XCTAssertFalse(viewModel.isSending, "the new chat isn't busy")
        let saved = store.all().first { $0.id == firstChat }
        let replies = saved?.messages.compactMap { message -> String? in
            if case .assistant(let text) = message.kind { return text } else { return nil }
        }
        XCTAssertEqual(replies, ["Logged your teh tarik."])
    }

    /// Going back to a chat while its reply is still coming shows it live.
    func testReturningToAChatStillWorkingShowsItLive() async {
        let context = TestSupport.makeContext()
        let service = GatedAssistantService(reply: "Here you go.")
        let viewModel = AssistantViewModel(service: service,
                                           executor: AssistantToolExecutor(context: context),
                                           contextBuilder: AssistantContextBuilder(context: context))

        viewModel.composerText = "Hi"
        let sending = Task { await viewModel.send() }
        await service.waitUntilCalled()
        let firstChat = viewModel.conversationID
        viewModel.startNewConversation()

        viewModel.open(SavedConversation(id: firstChat, title: "Hi", createdAt: .now,
                                         updatedAt: .now, messages: [], turns: []))
        XCTAssertTrue(viewModel.isSending, "still working when reopened")
        XCTAssertEqual(viewModel.messages.count, 1, "the live chat, not the saved copy")

        service.release()
        await sending.value
        XCTAssertEqual(viewModel.messages.count, 2)
    }
}

// MARK: - Profile, ranges and health notes

@MainActor
final class AssistantHealthToolsTests: XCTestCase {

    override func tearDown() {
        HealthNotesStore.shared.deleteAll()
        super.tearDown()
    }

    private func contextWithProfile() throws -> ModelContext {
        let context = TestSupport.makeContext()
        let profile = UserProfile(dateOfBirth: TestSupport.date(2004, 1, 1), sex: .female,
                                  heightCm: 163, weightKg: 100, targetWeightKg: 60,
                                  goal: .loseWeight, activity: .sedentary)
        context.insert(profile)
        context.insert(NutritionTarget(ranges: NutritionTargetCalculator.calculate(profile: profile).ranges))
        try context.save()
        return context
    }

    /// A new weigh-in updates the profile and recalculates the ranges.
    func testProfileUpdateRecalculatesRanges() throws {
        let context = try contextWithProfile()
        let before = try XCTUnwrap(context.loadNutritionTarget()).ranges.calories
        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "p", tool: .updateProfile, arguments: ["weightKg": .number(95)]))
        else { return XCTFail("expected a card") }
        guard case .profile(let update) = write.action else { return XCTFail() }
        XCTAssertEqual(update.lines, ["Weight 100 -> 95 kg"])

        _ = try executor.commit(write)
        XCTAssertEqual(context.loadUserProfile()?.weightKg, 95)
        XCTAssertLessThan(try XCTUnwrap(context.loadNutritionTarget()).ranges.calories.min, before.min)
    }

    func testProfileUpdateWithNothingNewIsRefused() throws {
        let outcome = AssistantToolExecutor(context: try contextWithProfile()).execute(
            AssistantToolCall(id: "p", tool: .updateProfile, arguments: ["weightKg": .number(100)]))
        guard case .failure = outcome else { return XCTFail("expected failure") }
    }

    /// Ranges the assistant sets are kept as set by hand.
    func testRangeUpdateIsSavedAsManual() throws {
        let context = try contextWithProfile()
        let executor = AssistantToolExecutor(context: context)
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "r", tool: .updateDailyRanges, arguments: ["ranges": .array([.object([
                "nutrient": .string("carbs"), "min": .number(120), "max": .number(150)])])]))
        else { return XCTFail("expected a card") }
        _ = try executor.commit(write)

        let carbs = try XCTUnwrap(context.loadNutritionTarget()).ranges.carbs
        XCTAssertEqual(carbs.min, 120)
        XCTAssertEqual(carbs.max, 150)
        XCTAssertTrue(carbs.isManuallyModified)
    }

    func testCaloriesCantGoBelowTheFloor() throws {
        let outcome = AssistantToolExecutor(context: try contextWithProfile()).execute(
            AssistantToolCall(id: "r", tool: .updateDailyRanges, arguments: ["ranges": .array([
                .object(["nutrient": .string("calories"), "min": .number(800), "max": .number(1000)])
            ])]))
        guard case .failure = outcome else { return XCTFail("expected failure") }
    }

    func testHealthNotesAreSaved() throws {
        let executor = AssistantToolExecutor(context: try contextWithProfile())
        guard case .awaitingConfirmation(let write) = executor.execute(AssistantToolCall(
            id: "h", tool: .saveHealthNotes, arguments: ["notes": .array([.object([
                "condition": .string("Prediabetes"),
                "details": .string("HbA1c 6.1% (20 Oct 2026)"),
                "guidance": .array([.string("At most 1 banana a day")])])])]))
        else { return XCTFail("expected a card") }
        _ = try executor.commit(write)

        XCTAssertEqual(HealthNotesStore.shared.notes.map(\.condition), ["Prediabetes"])
        XCTAssertEqual(HealthNotesStore.shared.notes.first?.guidance, ["At most 1 banana a day"])
    }
}
