import XCTest
@testable import NutritionTracker

@MainActor
final class EatenShareTests: XCTestCase {

    private func item(_ name: String) -> JSONValue {
        .object(["name": .string(name), "grams": .number(50)])
    }

    func testOneShareForEveryPartIsQuestioned() {
        let arguments: [String: JSONValue] = ["name": .string("Bowl"), "items": .array([
            item("Brown rice (about 85% eaten)"), item("Shoyu salmon (about 85% eaten)"),
            item("Tamago (about 85% eaten)"), item("Kimchi (about 85% eaten)")])]
        let problem = AssistantToolExecutor.uniformEatenShareProblem(in: arguments)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("85%") == true)
    }

    func testDifferentSharesPerPartAreFine() {
        let arguments: [String: JSONValue] = ["name": .string("Bowl"), "items": .array([
            item("Brown rice (about 60% eaten)"), item("Shoyu salmon"), item("Tamago"),
            item("Kimchi (about 40% eaten)")])]
        XCTAssertNil(AssistantToolExecutor.uniformEatenShareProblem(in: arguments))
    }

    func testSharesInsideSeparateFoodsCount() {
        let arguments: [String: JSONValue] = ["foods": .array([.object([
            "name": .string("Bowl"),
            "items": .array([item("Rice (70% eaten)"), item("Egg (70% eaten)"),
                             item("Corn (70% eaten)")])])])]
        XCTAssertNotNil(AssistantToolExecutor.uniformEatenShareProblem(in: arguments))
    }

    func testShareIsReadFromTheName() {
        XCTAssertEqual(AssistantToolExecutor.eatenShare(in: "Rice (about 85% eaten; height assumed)"), 85)
        XCTAssertEqual(AssistantToolExecutor.eatenShare(in: "Kimchi (40 % eaten)"), 40)
        XCTAssertNil(AssistantToolExecutor.eatenShare(in: "Salmon"))
    }
}
