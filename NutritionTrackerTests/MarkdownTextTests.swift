import XCTest
@testable import NutritionTracker

/// Assistant replies arrive as Markdown; the chat must format them rather
/// than show "**" and "-" literally.
final class MarkdownTextTests: XCTestCase {

    func testBlocksAreRecognised() {
        let blocks = MarkdownText.blocks(from: """
        ## Best fit
        **2 satay** and a small bowl of rice.

        - About 450 kcal
          - 25 g protein
        * Leaves room for dinner
        1. Order the satay
        2) Share the rice
        ---
        """)
        XCTAssertEqual(blocks, [
            .heading("Best fit"),
            .paragraph("**2 satay** and a small bowl of rice."),
            .bullet("About 450 kcal", level: 0),
            .bullet("25 g protein", level: 1),
            .bullet("Leaves room for dinner", level: 0),
            .numbered(marker: "1.", text: "Order the satay"),
            .numbered(marker: "2.", text: "Share the rice")
        ])
    }

    func testBoldIsFormattedNotShownAsAsterisks() {
        let rendered = MarkdownText.inline("Have **2 satay** today")
        XCTAssertEqual(String(rendered.characters), "Have 2 satay today")
        let boldRun = rendered.runs.first { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertNotNil(boldRun)
    }

    func testBrokenMarkdownFallsBackToPlainText() {
        let rendered = MarkdownText.inline("an unclosed **bold")
        XCTAssertTrue(String(rendered.characters).contains("bold"))
    }

    /// "2 eggs" or "12.5 g" mustn't be mistaken for a numbered list item.
    func testNumbersInSentencesStayParagraphs() {
        XCTAssertEqual(MarkdownText.blocks(from: "2 eggs and toast"), [.paragraph("2 eggs and toast")])
        XCTAssertEqual(MarkdownText.blocks(from: "12.5 g of fat"), [.paragraph("12.5 g of fat")])
    }
}
