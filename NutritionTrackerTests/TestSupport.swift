import Foundation
import SwiftData
@testable import NutritionTracker

/// Shared fixtures. Every date-sensitive test uses an explicit calendar and time
/// zone so results do not depend on the machine running them.
enum TestSupport {

    static func calendar(_ identifier: String = "Asia/Kuala_Lumpur") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = 2 // Monday, so week buckets are predictable
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0,
                     calendar: Calendar = TestSupport.calendar()) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute, second: second))!
    }

    @MainActor
    static func makeContext() -> ModelContext {
        ModelContext(AppModelContainer.makeInMemoryContainer())
    }

    static func entry(name: String = "Food",
                      at date: Date,
                      calories: Double = 100,
                      protein: Double = 10,
                      carbs: Double = 10,
                      fat: Double = 5,
                      quantity: Double = 1) -> FoodEntry {
        FoodEntry(name: name, consumedAt: date, quantity: quantity, servingSize: 1,
                  unit: .serving,
                  nutritionPerServing: Nutrition(calories: calories, protein: protein,
                                                 carbs: carbs, fat: fat))
    }

    static func ranges(calories: (Double, Double) = (1800, 2200),
                       protein: (Double, Double) = (120, 160)) -> NutritionTargetRanges {
        NutritionTargetRanges(calories: NutrientRange(min: calories.0, max: calories.1),
                              protein: NutrientRange(min: protein.0, max: protein.1),
                              carbs: NutrientRange(min: 180, max: 260),
                              fat: NutrientRange(min: 55, max: 75),
                              fibre: NutrientRange(min: 25, max: 35))
    }
}
