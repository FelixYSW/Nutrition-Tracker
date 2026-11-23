import XCTest
@testable import NutritionTracker

final class PlaceResolverTests: XCTestCase {

    func testNamedMallIsFoundInTheUsersMessage() {
        XCTAssertEqual(AssistantPlaceResolver.placeNamed(in: "what to eat in Sunway Pyramid"),
                       "Sunway Pyramid")
        XCTAssertEqual(AssistantPlaceResolver.placeNamed(in: "cheap dinner at Pavilion KL under RM20"),
                       "Pavilion KL")
        XCTAssertEqual(AssistantPlaceResolver.placeNamed(in: "high protein lunch around Mid Valley, halal"),
                       "Mid Valley")
        XCTAssertEqual(AssistantPlaceResolver.placeNamed(in: "what can I eat in sunway pyramid?"),
                       "sunway pyramid")
    }

    func testPhrasesThatAreNotPlacesAreIgnored() {
        XCTAssertNil(AssistantPlaceResolver.placeNamed(in: "what can I eat near me"))
        XCTAssertNil(AssistantPlaceResolver.placeNamed(in: "I'm in a rush, what's quick"))
        XCTAssertNil(AssistantPlaceResolver.placeNamed(in: "what should I eat in the morning"))
        XCTAssertNil(AssistantPlaceResolver.placeNamed(in: "how many calories in general"))
    }

    func testModelPlaceBeatsTheMessage() {
        let place = AssistantPlaceResolver.place(arguments: ["place": .string("Bangsar Village")],
                                                 userText: "what to eat at Pavilion")
        XCTAssertEqual(place, "Bangsar Village")
    }

    func testMessagePlaceUsedWhenTheModelLeftItOut() {
        let place = AssistantPlaceResolver.place(
            arguments: ["preferences": .string("high protein")],
            userText: "what to eat in Sunway Pyramid, high protein")
        XCTAssertEqual(place, "Sunway Pyramid")
    }

    func testNoPlaceMeansCurrentLocation() {
        XCTAssertNil(AssistantPlaceResolver.place(arguments: [:], userText: "what to eat near me"))
        XCTAssertNil(AssistantPlaceResolver.place(arguments: [:], userText: nil))
    }

    @MainActor
    func testNamedPlaceQuestionPinsTheVenueAndRegion() {
        let (question, activity) = AssistantViewModel.webQuestion(
            for: AssistantToolCall(id: "n", tool: .findFoodNearby, arguments: [:]),
            resolvedPlace: "Sunway Pyramid")
        XCTAssertTrue(question.contains("\"Sunway Pyramid\""))
        XCTAssertTrue(question.contains("Malaysia"))
        XCTAssertEqual(activity, "Searched for food at Sunway Pyramid")
    }

    func testLatestUserTextSkipsToolResults() {
        let turns: [AssistantTurn] = [
            .user("what to eat in Pavilion"),
            AssistantTurn(role: .assistant, blocks: [.toolUse(id: "1", name: "findFoodNearby", input: [:])]),
            AssistantTurn(role: .user, blocks: [.toolResult(id: "1", content: "{}", isError: false)])
        ]
        XCTAssertEqual(AssistantViewModel.latestUserText(in: turns), "what to eat in Pavilion")
    }
}

final class SearchCacheTests: XCTestCase {
    @MainActor
    func testSameQuestionWithDifferentSpacingIsOneSearch() {
        XCTAssertEqual(AssistantViewModel.searchCacheKey("Find  McChicken\nnutrition"),
                       AssistantViewModel.searchCacheKey("find mcchicken nutrition"))
    }
}

final class RestaurantSuggestionTests: XCTestCase {

    func testNamedRestaurantLooksUpItsMenuNotOneBranch() {
        let call = AssistantToolCall(id: "r", tool: .findFoodNearby,
                                     arguments: ["restaurant": .string("Saizeriya")])
        let (question, activity) = AssistantViewModel.webQuestion(for: call)
        XCTAssertTrue(question.contains("menu of the restaurant \"Saizeriya\""))
        XCTAssertTrue(question.contains("same at every branch"))
        XCTAssertEqual(activity, "Looked up the menu at Saizeriya")
    }

    func testRestaurantAreaOnlyFromTheCall() {
        let call = AssistantToolCall(id: "r", tool: .findFoodNearby,
                                     arguments: ["restaurant": .string("Sushi King"),
                                                 "place": .string("Mid Valley")])
        let (question, activity) = AssistantViewModel.webQuestion(for: call)
        XCTAssertTrue(question.contains("Mid Valley branch"))
        XCTAssertEqual(activity, "Looked up the menu at Sushi King, Mid Valley")
    }

    func testDishesSitUnderTheirPlace() {
        let blocks = MarkdownText.blocks(from: """
        1. **Pokok** - Level 2, grilled and light
        - **Avo Chicken** (RM34) - dressing on the side
        2. **Saizeriya** - Level 1
        - **Grilled chicken** (RM16)
        """)
        XCTAssertEqual(blocks[1], .bullet("**Avo Chicken** (RM34) - dressing on the side", level: 1))
        XCTAssertEqual(blocks[3], .bullet("**Grilled chicken** (RM16)", level: 1))
    }
}
