import Foundation
import SwiftData

/// The per-request context sent to the LLM (spec section 29A).
///
/// Deliberately scoped: profile essentials, today's target bands, today's
/// entries, and a short trend summary. The whole database is never serialised,
/// both to keep the payload small and to limit how much health-adjacent
/// personal data leaves the device (spec section 39).
struct AssistantContext: Codable, Equatable, Sendable {

    struct ProfileSummary: Codable, Equatable, Sendable {
        var age: Int
        var sex: String
        var heightCm: Double
        var weightKg: Double
        var goal: String
        var activityLevel: String
        /// Deliberately omitted from the payload: date of birth, target weight
        /// and body-fat percentage, none of which the assistant needs to answer
        /// "what should I eat".
    }

    struct RangeSummary: Codable, Equatable, Sendable {
        var nutrient: String
        var min: Double
        var max: Double
        var consumedToday: Double
        var remainingToMax: Double
        var neededToReachMin: Double
        var state: String
    }

    struct EntrySummary: Codable, Equatable, Sendable {
        /// Included so the model can reference an entry in an edit/delete call.
        var id: String
        var name: String
        var consumedAt: String
        var quantity: Double
        var unit: String
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var ingredientNames: [String]?
    }

    struct TrendSummary: Codable, Equatable, Sendable {
        var scale: String
        var bucketsWithData: Int
        var bucketsTotal: Int
        /// Per-nutrient under/within/over counts over the window.
        var nutrientTallies: [String: [String: Int]]
        var averageDailyCalories: Double?
    }

    var generatedAt: String
    var localDate: String
    var timezone: String
    var profile: ProfileSummary?
    var targetRanges: [RangeSummary]
    var entriesToday: [EntrySummary]
    var trend: TrendSummary?
    /// Plain-language note so the model does not invent numbers.
    var note: String
}

/// Assembles the context for one assistant request.
@MainActor
struct AssistantContextBuilder {

    private let context: ModelContext
    private let calendar: Calendar

    /// How far back the trend summary looks.
    nonisolated static let trendWindowDays = 14

    init(context: ModelContext, calendar: Calendar = .autoupdatingCurrent) {
        self.context = context
        self.calendar = calendar
    }

    func build(now: Date = .now) -> AssistantContext {
        let profile = context.loadUserProfile()
        let target = context.loadNutritionTarget()
        let todaysEntries = context.fetchEntries(on: now, calendar: calendar)
        let consumed = LocalDay.total(todaysEntries)

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var ranges: [AssistantContext.RangeSummary] = []
        if let target {
            let targetRanges = target.ranges
            for nutrient in Nutrient.allCases {
                let range = targetRanges[nutrient]
                let value = consumed[nutrient]
                ranges.append(.init(nutrient: nutrient.rawValue,
                                    min: range.min,
                                    max: range.max,
                                    consumedToday: value.rounded(),
                                    remainingToMax: max(0, range.max - value).rounded(),
                                    neededToReachMin: max(0, range.min - value).rounded(),
                                    state: range.state(consumed: value).rawValue))
            }
        }

        let entries = todaysEntries.map { entry in
            AssistantContext.EntrySummary(
                id: entry.id.uuidString,
                name: entry.name,
                consumedAt: AssistantArgumentParser.isoFormatter.string(from: entry.consumedAt),
                quantity: entry.quantity,
                unit: entry.unitRaw,
                calories: entry.total.calories.rounded(),
                protein: entry.total.protein.rounded(),
                carbs: entry.total.carbs.rounded(),
                fat: entry.total.fat.rounded(),
                ingredientNames: entry.isComposite
                    ? entry.orderedIngredients.map(\.name)
                    : nil)
        }

        return AssistantContext(
            generatedAt: AssistantArgumentParser.isoFormatter.string(from: now),
            localDate: dateFormatter.string(from: now),
            timezone: calendar.timeZone.identifier,
            profile: profile.map {
                .init(age: $0.age(on: now, calendar: calendar),
                      sex: $0.sexRaw,
                      heightCm: $0.heightCm,
                      weightKg: $0.weightKg,
                      goal: $0.goalRaw,
                      activityLevel: $0.activityRaw)
            },
            targetRanges: ranges,
            entriesToday: entries,
            trend: buildTrend(target: target, now: now),
            note: Self.note)
    }

    func buildTrend(target: NutritionTarget?, now: Date) -> AssistantContext.TrendSummary? {
        guard let target else { return nil }

        guard let windowStart = calendar.date(byAdding: .day,
                                               value: -Self.trendWindowDays,
                                               to: LocalDay.start(of: now, calendar: calendar))
        else { return nil }

        let entries = context.fetchEntries(from: windowStart,
                                           to: LocalDay.interval(containing: now,
                                                                 calendar: calendar).end)
        let buckets = TrendAggregator.buckets(entries: entries,
                                              scale: .daily,
                                              endingOn: now,
                                              count: Self.trendWindowDays,
                                              calendar: calendar)

        let ranges = target.ranges
        var tallies: [String: [String: Int]] = [:]
        for nutrient in Nutrient.allCases {
            let tally = TrendAggregator.tally(buckets: buckets,
                                              nutrient: nutrient,
                                              range: ranges[nutrient],
                                              scale: .daily)
            tallies[nutrient.rawValue] = [
                "under": tally.under,
                "within": tally.within,
                "over": tally.over,
                "noData": tally.noData
            ]
        }

        let withData = buckets.filter(\.hasData)
        let averageCalories: Double? = withData.isEmpty
            ? nil
            : (withData.reduce(0) { $0 + $1.total.calories } / Double(withData.count)).rounded()

        return .init(scale: TrendScale.daily.rawValue,
                     bucketsWithData: withData.count,
                     bucketsTotal: buckets.count,
                     nutrientTallies: tallies,
                     averageDailyCalories: averageCalories)
    }

    func encodedJSON(now: Date = .now) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(build(now: now))
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static let note = """
    All figures above are the user's real logged data and calculated target \
    ranges. Targets are ranges, not single numbers. Do not invent nutrition \
    values for foods you were not given; if you need a figure, state that it is \
    an estimate.
    """

    /// Plain disclosure shown in the assistant sheet. Informational only: there
    /// is no setting to change, but the user should still know what is sent.
    nonisolated static let dataSharingDisclosure = """
    To answer, the assistant sends your profile basics, today's targets and food \
    log, and a 14-day trend summary to an AI service. Food photos are never sent, \
    apart from a menu photo you attach yourself.
    """

    nonisolated static let systemPrompt = """
    You are the in-app nutrition assistant for a personal iPhone food-tracking \
    app. You help the user with four things:

    1. Suggesting what to eat, fitted to the room left in today's target ranges.
    2. Logging, editing and deleting food on request.
    3. Summarising their own logged trends.
    4. Suggesting improvements grounded only in their actual logged data.

    When to log:
    - Only propose an entry (addFoodEntry, editFoodEntry, deleteFoodEntry) when \
    the user says they ate, are eating or will eat something, or asks you to \
    log, change or delete an entry. A photo by itself is not a request to log.
    - If the user asks what to eat - from a menu, a photo of several dishes, or \
    a description - only reply with suggestions. Do not propose an entry until \
    they say what they actually had.
    - When you propose an entry, write no text with it: the app shows a \
    confirmation card, and that card is your whole reply.
    - Entries are only saved when the user taps the card, which happens outside \
    your control. Never claim something was logged, changed or deleted unless a \
    tool result says so.

    While a card is waiting (a tool result with status "awaiting_user"):
    - If the user asks to change it - add or remove a food, change an amount, \
    rename it - propose the complete amended entry again. It replaces the open \
    card, so include everything, not just the change.
    - If the user talks about anything else, just answer and leave the card \
    alone; do not propose it again.

    Suggesting what to eat:
    - Be direct. Say exactly what to have and how much, e.g. "2 sticks of satay \
    and a small bowl of fried rice (about 450 kcal, 25 g protein)".
    - Fit it to the room left in today's ranges from the context, and say in \
    one short line how it fits (e.g. "leaves about 200 kcal for dinner").
    - Give one recommendation, or at most two or three short options. No long \
    caveats, no lists of every dish.
    - Portions in everyday terms the user can order or serve: pieces, sticks, \
    bowls, plates, cups. Nutrition figures are rough; say "about".

    Logging rules:
    - Never state or estimate a total for the whole meal. Break it into \
    components with realistic grams for what the user actually ate - count \
    pieces and convert them (12 konjac knots is about 150 g, one egg about \
    50 g), and include cooking oil for fried or stir-fried dishes. The app \
    calculates the nutrition from its own database.
    - If the message includes an on-device photo analysis, log the foods and \
    grams it lists unless the user corrects them.

    General:
    - Targets are ranges with a minimum and a maximum, never a single number. \
    Being under the minimum earlier in the day is normal, not a failure.
    - Ground every claim about the user's intake in the context or a tool \
    result. Do not invent numbers or trends.
    - This is not medical advice and you must not present it as such. Do not \
    diagnose, and do not comment on the user's body or weight beyond the \
    nutrition arithmetic they asked for.
    - Be concise. The user is on a phone.
    """
}
