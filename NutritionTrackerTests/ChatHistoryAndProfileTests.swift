import XCTest
import SwiftData
@testable import NutritionTracker

// MARK: - Training days

final class TrainingDaysTests: XCTestCase {

    func testChangedValueWinsAndTheOtherGivesWay() {
        let result = TrainingDaysEditor.adjust(changed: 5, other: 4)
        XCTAssertEqual(result.changed, 5)
        XCTAssertEqual(result.other, 2, "5 + 2 fills the week")
    }

    func testValuesThatFitAreLeftAlone() {
        let result = TrainingDaysEditor.adjust(changed: 3, other: 2)
        XCTAssertEqual(result.changed, 3)
        XCTAssertEqual(result.other, 2)
    }

    func testValuesAreClampedToOneWeek() {
        let result = TrainingDaysEditor.adjust(changed: 12, other: 1)
        XCTAssertEqual(result.changed, 7)
        XCTAssertEqual(result.other, 0)
    }

    /// Earlier versions allowed up to 14 of each.
    func testOldValuesAreBroughtIntoOneWeek() {
        let fixed = TrainingDaysEditor.normalised(strength: 6, cardio: 6)
        XCTAssertEqual(fixed.strength + fixed.cardio, 7)
        XCTAssertEqual(TrainingDaysEditor.normalised(strength: 3, cardio: 2).strength, 3)
        XCTAssertEqual(TrainingDaysEditor.normalised(strength: 14, cardio: 0).strength, 7)
    }
}

// MARK: - Targets follow the profile

@MainActor
final class TargetUpdaterTests: XCTestCase {

    private func makeProfile(weight: Double = 80) -> UserProfile {
        UserProfile(dateOfBirth: TestSupport.date(1995, 1, 1), sex: .male, heightCm: 180,
                    weightKg: weight, goal: .maintain, activity: .moderate)
    }

    func testChangingWeightRecalculatesTargets() throws {
        let context = TestSupport.makeContext()
        let profile = makeProfile()
        context.insert(profile)
        TargetUpdater.update(for: profile, in: context)
        let before = try XCTUnwrap(context.loadNutritionTarget()).calories

        profile.weightKg = 95
        TargetUpdater.update(for: profile, in: context)
        let after = try XCTUnwrap(context.loadNutritionTarget()).calories
        XCTAssertGreaterThan(after.max, before.max, "heavier means a higher calorie range")
    }

    func testHandEditedBoundsSurviveAutomaticUpdates() throws {
        let context = TestSupport.makeContext()
        let profile = makeProfile()
        context.insert(profile)
        TargetUpdater.update(for: profile, in: context)
        let target = try XCTUnwrap(context.loadNutritionTarget())
        target.protein = target.protein.withManualMin(170)

        profile.goal = .loseWeight
        TargetUpdater.update(for: profile, in: context)
        XCTAssertEqual(context.loadNutritionTarget()?.protein.min, 170)
    }

    func testOnlyCalculationInputsCountAsChanges() {
        let profile = makeProfile()
        let original = TargetInputs(profile)
        profile.strengthSessionsPerWeek = 4
        XCTAssertEqual(TargetInputs(profile), original, "training days don't change the maths")
        profile.heightCm = 181
        XCTAssertNotEqual(TargetInputs(profile), original)
    }
}

// MARK: - Chat history

final class ChatHistoryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chats-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func conversation(_ title: String, updated: Date,
                              messages: [AssistantChatMessage] = []) -> SavedConversation {
        SavedConversation(id: UUID(), title: title, createdAt: updated, updatedAt: updated,
                          messages: messages, turns: [.user(title)])
    }

    func testSavesAndListsNewestFirst() {
        let store = ChatHistoryStore(directory: directory)
        store.save(conversation("Older", updated: Date(timeIntervalSince1970: 1_000)))
        store.save(conversation("Newer", updated: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(store.all().map(\.title), ["Newer", "Older"])
    }

    func testRoundTripKeepsMessagesPhotosAndCards() throws {
        let store = ChatHistoryStore(directory: directory)
        let write = PendingAssistantWrite(id: "c1", tool: .addFoodEntry,
                                          action: .add(FoodEntryDraft(name: "Teh Tarik")))
        let saved = conversation("Lunch", updated: .now, messages: [
            AssistantChatMessage(kind: .user(text: "lunch?", images: [Data([1, 2, 3])])),
            AssistantChatMessage(kind: .proposal(write)),
            AssistantChatMessage(kind: .proposalResolved(summary: "Added Teh Tarik.", confirmed: true))
        ])
        store.save(saved)
        let loaded = try XCTUnwrap(store.all().first)
        XCTAssertEqual(loaded.messages, saved.messages)
        XCTAssertEqual(loaded.turns, saved.turns)
    }

    func testDeleteAndDeleteAll() {
        let store = ChatHistoryStore(directory: directory)
        let first = conversation("A", updated: .now)
        store.save(first)
        store.save(conversation("B", updated: .now))
        store.delete(id: first.id)
        XCTAssertEqual(store.all().map(\.title), ["B"])
        store.deleteAll()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testOldestChatsAreTrimmed() {
        let store = ChatHistoryStore(directory: directory)
        for index in 0..<(ChatHistoryStore.maximumConversations + 3) {
            store.save(conversation("\(index)", updated: Date(timeIntervalSince1970: Double(index))))
        }
        let titles = store.all().map(\.title)
        XCTAssertEqual(titles.count, ChatHistoryStore.maximumConversations)
        XCTAssertFalse(titles.contains("0"), "oldest removed first")
    }

    func testTitleComesFromTheFirstQuestion() {
        XCTAssertEqual(SavedConversation.title(for: [
            AssistantChatMessage(kind: .user(text: "What should I eat?\nMore", images: []))
        ]), "What should I eat?")
        XCTAssertEqual(SavedConversation.title(for: [
            AssistantChatMessage(kind: .user(text: "", images: [Data([1]), Data([2])]))
        ]), "2 photos")
        XCTAssertEqual(SavedConversation.title(for: []), "New chat")
    }
}

@MainActor
final class ConversationSwitchingTests: XCTestCase {

    private func makeViewModel(store: ChatHistoryStore,
                               responses: [AssistantResponse]) -> AssistantViewModel {
        let context = TestSupport.makeContext()
        return AssistantViewModel(service: ScriptedAssistantService(responses),
                                  executor: AssistantToolExecutor(context: context),
                                  contextBuilder: AssistantContextBuilder(context: context),
                                  historyStore: store)
    }

    private func temporaryStore() -> ChatHistoryStore {
        ChatHistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("chats-\(UUID().uuidString)", isDirectory: true))
    }

    func testChatIsSavedAndCanBeReopened() async throws {
        let store = temporaryStore()
        let viewModel = makeViewModel(store: store, responses: [
            AssistantResponse(text: "Try the soup.", toolCalls: [])])
        viewModel.composerText = "what should I eat?"
        await viewModel.send()

        let saved = try XCTUnwrap(store.all().first)
        XCTAssertEqual(saved.title, "what should I eat?")

        viewModel.startNewConversation()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNotEqual(viewModel.conversationID, saved.id)

        viewModel.open(saved)
        XCTAssertEqual(viewModel.conversationID, saved.id)
        XCTAssertEqual(viewModel.messages, saved.messages)
    }

    func testEmptyChatsAreNotSaved() {
        let store = temporaryStore()
        let viewModel = makeViewModel(store: store, responses: [])
        viewModel.startNewConversation()
        XCTAssertTrue(store.all().isEmpty)
    }

    /// A chat saved with a card still open is repaired on reopening, so the
    /// next request isn't rejected for an unanswered tool call.
    func testUnansweredToolCallsAreClosedOnReopen() {
        let turns: [AssistantTurn] = [
            .user("I had a salad"),
            AssistantTurn(role: .assistant, blocks: [
                .toolUse(id: "open", name: "addFoodEntry", input: [:])])
        ]
        let repaired = AssistantViewModel.closingUnansweredToolCalls(in: turns)
        XCTAssertEqual(repaired.count, 3)
        guard case .toolResult(let id, let content, _) = repaired.last?.blocks.first else {
            return XCTFail("expected a closing tool result")
        }
        XCTAssertEqual(id, "open")
        XCTAssertTrue(content.contains("closed"))

        let complete = repaired
        XCTAssertEqual(AssistantViewModel.closingUnansweredToolCalls(in: complete), complete,
                       "nothing to repair")
    }
}
