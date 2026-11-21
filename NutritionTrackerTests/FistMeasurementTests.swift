import XCTest
import CoreGraphics
@testable import NutritionTracker

final class FistMeasurementTests: XCTestCase {

    /// A card lying square in the photo: 856 x 540 px, i.e. 0.1 mm per pixel.
    private let card = FistMeasurement.Quad(topLeft: CGPoint(x: 100, y: 100),
                                            topRight: CGPoint(x: 956, y: 100),
                                            bottomRight: CGPoint(x: 956, y: 640),
                                            bottomLeft: CGPoint(x: 100, y: 640))

    func testCardGivesTheScale() throws {
        let scale = try XCTUnwrap(FistMeasurement.millimetresPerPixel(card: card))
        XCTAssertEqual(scale, 0.1, accuracy: 0.001)
    }

    func testCardTurnedSidewaysGivesTheSameScale() throws {
        let portrait = FistMeasurement.Quad(topLeft: CGPoint(x: 0, y: 0),
                                            topRight: CGPoint(x: 540, y: 0),
                                            bottomRight: CGPoint(x: 540, y: 856),
                                            bottomLeft: CGPoint(x: 0, y: 856))
        let scale = try XCTUnwrap(FistMeasurement.millimetresPerPixel(card: portrait))
        XCTAssertEqual(scale, 0.1, accuracy: 0.001)
    }

    func testShapeThatIsNotACardIsRejected() {
        // A square: a phone screen or a coaster, not a card.
        let square = FistMeasurement.Quad(topLeft: .zero, topRight: CGPoint(x: 500, y: 0),
                                          bottomRight: CGPoint(x: 500, y: 500),
                                          bottomLeft: CGPoint(x: 0, y: 500))
        XCTAssertNil(FistMeasurement.millimetresPerPixel(card: square))
    }

    func testWidthBetweenTheDotsInCentimetres() {
        // 870 px apart at 0.1 mm per pixel = 87 mm.
        let width = FistMeasurement.widthCm(from: CGPoint(x: 100, y: 300),
                                            to: CGPoint(x: 970, y: 300),
                                            millimetresPerPixel: 0.1)
        XCTAssertEqual(width, 8.7, accuracy: 0.001)
    }

    func testKnuckleCentresAreWidenedToTheEdges() {
        let (index, little) = FistMeasurement.knuckleEdges(index: CGPoint(x: 160, y: 0),
                                                           little: CGPoint(x: 100, y: 0))
        XCTAssertGreaterThan(index.x, 160)
        XCTAssertLessThan(little.x, 100)
        // Symmetric about the middle.
        XCTAssertEqual((index.x + little.x) / 2, 130, accuracy: 0.001)
    }

    func testVolumeScalesWithTheCubeOfTheWidth() {
        let average = HandReference(fistWidthCm: 8.5, measuredAt: .now, method: .manual)
        XCTAssertEqual(average.approximateVolumeMl, 250)
        let bigger = HandReference(fistWidthCm: 10.2, measuredAt: .now, method: .scan)
        XCTAssertGreaterThan(bigger.approximateVolumeMl, 400)
    }

    func testStoreKeepsAndClearsTheValue() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FistMeasurementTests"))
        defaults.removePersistentDomain(forName: "FistMeasurementTests")
        let store = HandReferenceStore(defaults: defaults)
        XCTAssertNil(store.reference)

        let value = HandReference(fistWidthCm: 9.1, measuredAt: Date(timeIntervalSince1970: 0),
                                  method: .scan)
        store.reference = value
        XCTAssertEqual(HandReferenceStore(defaults: defaults).reference, value)

        store.reference = nil
        XCTAssertNil(store.reference)
    }

    @MainActor
    func testContextCarriesTheFistOnlyWhenMeasured() throws {
        let context = TestSupport.makeContext()
        let without = AssistantContextBuilder(context: context, handReference: { nil }).build()
        XCTAssertNil(without.handReference)

        let fist = HandReference(fistWidthCm: 9.0, measuredAt: .now, method: .scan)
        let with = AssistantContextBuilder(context: context, handReference: { fist }).build()
        XCTAssertEqual(with.handReference?.fistWidthCm, 9.0)
        XCTAssertEqual(with.handReference?.fistVolumeMlApprox, fist.approximateVolumeMl)
    }

    func testPromptExplainsBeforeAndAfterPhotos() {
        let prompt = AssistantContextBuilder.systemPrompt
        XCTAssertTrue(prompt.contains("Eaten = before minus after"))
        XCTAssertTrue(prompt.contains("handReference"))
        XCTAssertTrue(prompt.contains("Size before grams"))
    }
}

@MainActor
final class FistCaptureGuideTests: XCTestCase {

    func testImagePointMapsToTheFilledScreen() {
        // A 1080 x 1920 frame shown on a 390 x 844 screen, cropped at the sides.
        let view = CGSize(width: 390, height: 844)
        let centre = FistCaptureView.viewPoint(CGPoint(x: 0.5, y: 0.5),
                                               imageSize: CGSize(width: 1080, height: 1920),
                                               viewSize: view)
        XCTAssertEqual(centre.x, 195, accuracy: 0.5)
        XCTAssertEqual(centre.y, 422, accuracy: 0.5)
    }

    func testCardMustFillItsOutline() {
        let guide = FistCaptureView.cardGuide(in: CGSize(width: 390, height: 844))
        let filling = [CGPoint(x: guide.minX, y: guide.minY), CGPoint(x: guide.maxX, y: guide.minY),
                       CGPoint(x: guide.maxX, y: guide.maxY), CGPoint(x: guide.minX, y: guide.maxY)]
        XCTAssertTrue(FistCaptureView.cardFits(filling, in: guide))

        // A small card in the middle of the outline: too far away to trust.
        let small = filling.map { CGPoint(x: guide.midX + ($0.x - guide.midX) * 0.4,
                                          y: guide.midY + ($0.y - guide.midY) * 0.4) }
        XCTAssertFalse(FistCaptureView.cardFits(small, in: guide))

        // Outside the outline altogether.
        let elsewhere = filling.map { CGPoint(x: $0.x, y: $0.y + 400) }
        XCTAssertFalse(FistCaptureView.cardFits(elsewhere, in: guide))
    }
}
