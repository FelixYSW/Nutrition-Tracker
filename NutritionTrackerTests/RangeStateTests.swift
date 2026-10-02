import XCTest
import SwiftData
@testable import NutritionTracker

final class RangeStateTests: XCTestCase {

    private let range = NutrientRange(min: 120, max: 160)

    func testUnderBelowMinimum() {
        XCTAssertEqual(range.state(consumed: 0), .under)
        XCTAssertEqual(range.state(consumed: 119.99), .under)
    }

    func testExactlyAtMinimumIsWithin() {
        XCTAssertEqual(range.state(consumed: 120), .within)
    }

    func testExactlyAtMaximumIsWithin() {
        XCTAssertEqual(range.state(consumed: 160), .within)
    }

    func testOverAboveMaximum() {
        XCTAssertEqual(range.state(consumed: 160.01), .over)
        XCTAssertTrue(range.state(consumed: 200).isFlagged)
    }

    func testUnderIsNotFlagged() {
        // Being under is the normal state for most of the day.
        XCTAssertFalse(RangeState.under.isFlagged)
        XCTAssertFalse(RangeState.within.isFlagged)
    }

    func testZeroRangeNeverFlags() {
        XCTAssertEqual(NutrientRange.zero.state(consumed: 500), .within)
        XCTAssertEqual(NutrientRange.zero.progress(consumed: 500), 0)
    }

    func testInvertedBoundsAreNormalised() {
        let inverted = NutrientRange(min: 200, max: 100)
        XCTAssertEqual(inverted.min, 100)
        XCTAssertEqual(inverted.max, 200)
    }

    func testNegativeBoundsClampToZero() {
        let negative = NutrientRange(min: -50, max: 20)
        XCTAssertEqual(negative.min, 0)
    }

    func testBandFractionsForRingShading() {
        let fractions = range.bandFractions()
        XCTAssertEqual(fractions.start, 0.75, accuracy: 0.0001)
        XCTAssertEqual(fractions.end, 1)
    }

    func testProgressScaledToMaximum() {
        XCTAssertEqual(range.progress(consumed: 80), 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(range.progress(consumed: 200), 1)
    }

    func testBandAroundPointFraction() {
        let band = NutrientRange.band(around: 2000, fraction: 0.1)
        XCTAssertEqual(band.min, 1800)
        XCTAssertEqual(band.max, 2200)
        XCTAssertEqual(NutrientRange.band(around: .nan, fraction: 0.1), .zero)
    }

    func testManualEditsSetOnlyTheirOwnFlag() {
        let editedMin = range.withManualMin(130)
        XCTAssertTrue(editedMin.minManuallyModified)
        XCTAssertFalse(editedMin.maxManuallyModified)

        let editedMax = range.withManualMax(150)
        XCTAssertFalse(editedMax.minManuallyModified)
        XCTAssertTrue(editedMax.maxManuallyModified)
    }

    func testManualMinAboveMaxPushesMaxUp() {
        let edited = range.withManualMin(200)
        XCTAssertEqual(edited.min, 200)
        XCTAssertEqual(edited.max, 200)
    }

    func testRemainingAndNeededToReachMinimum() {
        let ranges = TestSupport.ranges()
        let consumed = Nutrition(calories: 1000, protein: 130, carbs: 300, fat: 20, fibre: 10)
        let remaining = ranges.remaining(consumed: consumed)
        XCTAssertEqual(remaining.calories, 1200)
        XCTAssertEqual(remaining.carbs, 0, "over the max floors at zero")

        let needed = ranges.neededToReachMinimum(consumed: consumed)
        XCTAssertEqual(needed.calories, 800)
        XCTAssertEqual(needed.protein, 0, "already within range")
    }

    /// Recalculating must never discard a bound the user edited by hand.
    @MainActor
    func testRecalculationPreservesManualBounds() {
        let context = TestSupport.makeContext()
        var original = TestSupport.ranges()
        original.protein = original.protein.withManualMin(150)
        let target = NutritionTarget(ranges: original)
        context.insert(target)

        let recalculated = NutritionTargetRanges(
            calories: NutrientRange(min: 2400, max: 2800),
            protein: NutrientRange(min: 100, max: 140),
            carbs: NutrientRange(min: 200, max: 300),
            fat: NutrientRange(min: 60, max: 80),
            fibre: NutrientRange(min: 30, max: 40))
        target.apply(recalculated: recalculated)

        XCTAssertEqual(target.protein.min, 150, "manual min kept")
        XCTAssertTrue(target.protein.minManuallyModified)
        XCTAssertEqual(target.protein.max, 150, "max raised so the band stays valid")
        XCTAssertEqual(target.calories, recalculated.calories, "untouched bounds update")
    }
}
