import Foundation
import SwiftData

/// Outcome of handing a tool call to the executor.
enum AssistantToolOutcome: Equatable, Sendable {
    /// A read-only tool ran; the JSON string goes back to the model.
    case result(String)
    /// A write was proposed and is waiting for the user. Nothing has been
    /// written yet.
    case awaitingConfirmation(PendingAssistantWrite)
    /// Several separate foods from one call, one card each.
    case awaitingConfirmations([PendingAssistantWrite])
    /// The tool call could not be used at all.
    case failure(String)

    var isWriteProposal: Bool {
        switch self {
        case .awaitingConfirmation, .awaitingConfirmations: true
        default: false
        }
    }
}

/// Executes assistant tool calls against the same SwiftData operations the rest
/// of the app uses (spec section 29A).
///
/// The confirmation gate lives here and nowhere else: `execute` can only ever
/// *propose* a write, and `commit` is the single method that mutates the
/// database. There is no code path from a model response to a saved entry that
/// skips it - not even for a "simple" edit.
@MainActor
final class AssistantToolExecutor {

    private let context: ModelContext
    private let calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .autoupdatingCurrent) {
        self.context = context
        self.calendar = calendar
    }

    // MARK: Execute (never writes)

    func execute(_ call: AssistantToolCall) -> AssistantToolOutcome {
        do {
            switch call.tool {
            case .queryEntries:
                return .result(try queryEntries(arguments: call.arguments))
            case .getTrends:
                return .result(try getTrends(arguments: call.arguments))
            case .calculateNutrition:
                return .result(try calculateNutrition(arguments: call.arguments))
            case .findFoodNearby, .lookUpProductNutrition, .findProducts:
                // Needs the network: the view model runs it through the service.
                return .failure("Web search is not run by the local executor.")
            case .addFoodEntry:
                let writes = try proposeAdd(call: call)
                return writes.count == 1 ? .awaitingConfirmation(writes[0]) : .awaitingConfirmations(writes)
            case .editFoodEntry:
                return .awaitingConfirmation(try proposeEdit(call: call))
            case .deleteFoodEntry:
                return .awaitingConfirmation(try proposeDelete(call: call))
            }
        } catch let error as AssistantToolError {
            return .failure(error.localizedDescription)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Read tools

    private func queryEntries(arguments: [String: JSONValue]) throws -> String {
        let now = Date.now
        let start = AssistantArgumentParser.parseDate(arguments["startDate"])
            ?? LocalDay.start(of: now, calendar: calendar)
        let end = AssistantArgumentParser.parseDate(arguments["endDate"])
            ?? LocalDay.interval(containing: now, calendar: calendar).end

        guard end > start else {
            throw AssistantToolError.malformedArguments(
                tool: AssistantTool.queryEntries.rawValue,
                detail: "endDate must be after startDate")
        }

        let entries = context.fetchEntries(from: start, to: end)
        let total = LocalDay.total(entries)

        struct Payload: Encodable {
            struct Row: Encodable {
                let id: String
                let name: String
                let consumedAt: String
                let quantity: Double
                let unit: String
                let calories: Double
                let protein: Double
                let carbs: Double
                let fat: Double
            }
            let startDate: String
            let endDate: String
            let entryCount: Int
            let totals: [String: Double]
            let entries: [Row]
        }

        let payload = Payload(
            startDate: AssistantArgumentParser.isoFormatter.string(from: start),
            endDate: AssistantArgumentParser.isoFormatter.string(from: end),
            entryCount: entries.count,
            totals: ["calories": total.calories.rounded(),
                     "protein": total.protein.rounded(),
                     "carbs": total.carbs.rounded(),
                     "fat": total.fat.rounded(),
                     "fibre": total.fibre.rounded()],
            entries: entries.map { entry in
                .init(id: entry.id.uuidString,
                      name: entry.name,
                      consumedAt: AssistantArgumentParser.isoFormatter
                          .string(from: entry.consumedAt),
                      quantity: entry.quantity,
                      unit: entry.unitRaw,
                      calories: entry.total.calories.rounded(),
                      protein: entry.total.protein.rounded(),
                      carbs: entry.total.carbs.rounded(),
                      fat: entry.total.fat.rounded())
            })

        return try encode(payload)
    }

    /// The figures a card would show for these foods, with nothing logged, so
    /// what the assistant says matches the card it later proposes.
    private func calculateNutrition(arguments: [String: JSONValue]) throws -> String {
        struct Food: Encodable {
            struct Item: Encodable {
                let name: String
                let grams: Double
                let calories: Double
                let source: String
            }
            let name: String
            let calories: Double
            let protein: Double
            let carbs: Double
            let fat: Double
            let fibre: Double
            let items: [Item]
        }
        let foods = try Self.foods(in: arguments).map { food -> Food in
            let draft = try proposeDraft(food)
            let total = draft.total
            let items = draft.isComposite
                ? draft.ingredients
                : [IngredientDraft(name: draft.name, quantity: draft.quantity, servingSize: 100,
                                   nutritionPerServing: draft.nutritionPerServing)]
            return Food(name: draft.name,
                        calories: total.calories.rounded(),
                        protein: total.protein.rounded(),
                        carbs: total.carbs.rounded(),
                        fat: total.fat.rounded(),
                        fibre: total.fibre.rounded(),
                        items: items.map {
                            .init(name: $0.name, grams: $0.quantity,
                                  calories: $0.total.calories.rounded(),
                                  source: $0.provenance.isEstimate ? "estimate"
                                      : $0.provenance.displayName)
                        })
        }
        return try encode(["foods": foods])
    }

    private func getTrends(arguments: [String: JSONValue]) throws -> String {
        let scale = AssistantArgumentParser.parseTrendScale(arguments["timeframe"])
        let now = Date.now
        let periods = min(AssistantTool.maxTrendPeriods,
                          max(1, Int(arguments["periods"]?.doubleValue ?? Double(scale.bucketCount))))

        let intervals = TrendAggregator.intervals(scale: scale, endingOn: now,
                                                   count: periods,
                                                   calendar: calendar)
        guard let windowStart = intervals.first?.start,
              let windowEnd = intervals.last?.end else {
            return try encode(["buckets": [String]()])
        }

        let entries = context.fetchEntries(from: windowStart, to: windowEnd)
        let buckets = TrendAggregator.buckets(entries: entries, scale: scale,
                                               endingOn: now, count: periods, calendar: calendar)
        let ranges = context.loadNutritionTarget()?.ranges

        // Each logged day's totals: weekly and monthly views need more than
        // one average per period - how consistently each range was met.
        let dayTotals = Dictionary(grouping: entries) {
            LocalDay.start(of: $0.consumedAt, calendar: calendar)
        }.mapValues { $0.reduce(Nutrition.zero) { $0 + $1.total } }

        struct Payload: Encodable {
            struct Bucket: Encodable {
                let label: String
                let startDate: String
                let hasData: Bool
                let isSparse: Bool
                let daysWithEntries: Int
                let elapsedDays: Int
                let calories: Double
                let protein: Double
                let carbs: Double
                let fat: Double
                let fibre: Double
                let states: [String: String]?
                /// Per nutrient, how many logged days were under, within or over.
                let dayStates: [String: [String: Int]]?
            }
            struct Summary: Encodable {
                let daysLogged: Int
                let averagePerLoggedDay: [String: Double]
                let weekdayAverage: [String: Double]?
                let weekendAverage: [String: Double]?
                let dayStates: [String: [String: Int]]?
            }
            let timeframe: String
            let plots: String
            let buckets: [Bucket]
            let summary: Summary
        }

        func averages(_ days: [Nutrition]) -> [String: Double]? {
            guard !days.isEmpty else { return nil }
            let total = days.reduce(Nutrition.zero, +)
            let count = Double(days.count)
            return Dictionary(uniqueKeysWithValues: Nutrient.allCases.map {
                ($0.rawValue, (total[$0] / count).rounded())
            })
        }

        func tallies(_ days: [Nutrition]) -> [String: [String: Int]]? {
            guard let ranges, !days.isEmpty else { return nil }
            return Dictionary(uniqueKeysWithValues: Nutrient.allCases.map { nutrient in
                var counts = ["under": 0, "within": 0, "over": 0]
                for day in days {
                    counts[ranges[nutrient].state(consumed: day[nutrient]).rawValue, default: 0] += 1
                }
                return (nutrient.rawValue, counts)
            })
        }

        func days(in interval: DateInterval) -> [Nutrition] {
            // Half-open: the next period's first day starts exactly at `end`.
            dayTotals.filter { $0.key >= interval.start && $0.key < interval.end }.map(\.value)
        }

        let allDays = Array(dayTotals.values)
        let weekend = dayTotals.filter { calendar.isDateInWeekend($0.key) }.map(\.value)
        let weekday = dayTotals.filter { !calendar.isDateInWeekend($0.key) }.map(\.value)
        let summary = Payload.Summary(daysLogged: allDays.count,
                                      averagePerLoggedDay: averages(allDays) ?? [:],
                                      weekdayAverage: averages(weekday),
                                      weekendAverage: averages(weekend),
                                      dayStates: tallies(allDays))

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        // A formatter ignores its calendar's time zone and uses the device's
        // unless told otherwise (UTC on CI), which can shift the date by a day.
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let payload = Payload(
            timeframe: scale.rawValue,
            plots: scale.plotsDailyAverage ? "daily average" : "daily total",
            buckets: buckets.map { bucket in
                let value = bucket.plotValue(for: scale)
                var states: [String: String]?
                if let ranges, bucket.hasData {
                    states = Dictionary(uniqueKeysWithValues: Nutrient.allCases.map {
                        ($0.rawValue, ranges[$0].state(consumed: value[$0]).rawValue)
                    })
                }
                return .init(label: bucket.label,
                             startDate: dateFormatter.string(from: bucket.interval.start),
                             hasData: bucket.hasData,
                             isSparse: bucket.isSparse,
                             daysWithEntries: bucket.daysWithEntries,
                             elapsedDays: bucket.elapsedDays,
                             calories: value.calories.rounded(),
                             protein: value.protein.rounded(),
                             carbs: value.carbs.rounded(),
                             fat: value.fat.rounded(),
                             fibre: value.fibre.rounded(),
                             states: states,
                             dayStates: scale == .daily ? nil : tallies(days(in: bucket.interval)))
            },
            summary: summary)

        return try encode(payload)
    }

    // MARK: Write proposals (still no writes)

    /// One card per food. A call listing several separate foods in `foods`
    /// gives each its own card, with ids "<call id>#1", "#2", ...; a single
    /// food (or the older name + items form) keeps the call id.
    private func proposeAdd(call: AssistantToolCall) throws -> [PendingAssistantWrite] {
        let foods = Self.foods(in: call.arguments)
        return try foods.enumerated().map { index, arguments in
            let id = foods.count == 1 ? call.id : "\(call.id)#\(index + 1)"
            return PendingAssistantWrite(id: id, tool: .addFoodEntry,
                                         action: .add(try proposeDraft(arguments)))
        }
    }

    /// The separate foods in an add call. Each inherits the call-wide time
    /// when it has none of its own.
    static func foods(in arguments: [String: JSONValue]) -> [[String: JSONValue]] {
        guard let list = arguments["foods"]?.arrayValue, !list.isEmpty else { return [arguments] }
        return list.compactMap(\.objectValue).map { food in
            var food = food
            if food["consumedAt"] == nil, let shared = arguments["consumedAt"] {
                food["consumedAt"] = shared
            }
            return food
        }
    }

    private func proposeDraft(_ arguments: [String: JSONValue]) throws -> FoodEntryDraft {
        let repository = NutritionRepository(context: context)
        try AssistantArgumentParser.checkItems(arguments["items"], tool: .addFoodEntry)
        try Self.checkLabelFigures(arguments["items"], tool: .addFoodEntry)
        let items = AssistantArgumentParser.parseItems(arguments["items"]) {
            Self.resolve($0, with: repository)
        } ?? []
        try Self.requireNutrition(items, tool: .addFoodEntry)
        return try AssistantArgumentParser.parseAdd(arguments: arguments) { item in
            Self.resolve(item, with: repository)
        }
    }

    // MARK: Sanity checks on the model's figures

    /// Words for drinks and foods that really have next to no energy, so zero
    /// figures for them are believable.
    static let nearZeroEnergyWords: Set<String> = [
        "water", "tea", "coffee", "americano", "espresso", "diet", "zero", "sparkling",
        "ice", "unsweetened", "sugarless"
    ]

    /// Items left with no energy at all - no database match and no figures from
    /// the model - would log as 0 kcal. The model is asked to supply them.
    static func requireNutrition(_ items: [IngredientDraft], tool: AssistantTool) throws {
        let missing = items.filter { item in
            let value = item.nutritionPerServing
            guard value.calories <= 0, value.energyFromMacros <= 0 else { return false }
            let words = Set(item.name.lowercased().split { !$0.isLetter }.map(String.init))
            return words.isDisjoint(with: nearZeroEnergyWords)
        }.map(\.name)
        guard !missing.isEmpty else { return }
        throw AssistantToolError.malformedArguments(
            tool: tool.rawValue,
            detail: "no nutrition figures for \(missing.joined(separator: ", ")). Send "
                + "kcalPer100g, proteinPer100g, carbsPer100g and fatPer100g for each - for a "
                + "brand, the figures from lookUpProductNutrition with nutritionSource \"brand\"")
    }

    /// Label and brand figures are used exactly as given, so they must be
    /// complete and add up: a label always states energy, protein, carbs and
    /// fat, and its energy is close to 4/4/9 kcal per gram of them. A missing
    /// value (e.g. protein left out, showing as 0 g) or a big mismatch means the
    /// label was misread, and the model is asked to read it again.
    static func checkLabelFigures(_ itemsValue: JSONValue?, tool: AssistantTool) throws {
        var problems: [String] = []
        for value in itemsValue?.arrayValue ?? [] {
            guard let item = value.objectValue,
                  let source = item["nutritionSource"]?.stringValue?.lowercased(),
                  source == "label" || source == "brand" else { continue }
            let name = item["name"]?.stringValue ?? "an item"
            let keys = ["kcalPer100g", "proteinPer100g", "carbsPer100g", "fatPer100g"]
            let absent = keys.filter { item[$0]?.doubleValue == nil }
            if !absent.isEmpty {
                problems.append("\(name) is missing \(absent.joined(separator: ", "))")
                continue
            }
            let kcal = item["kcalPer100g"]?.doubleValue ?? 0
            let fromMacros = 4 * (item["proteinPer100g"]?.doubleValue ?? 0)
                + 4 * (item["carbsPer100g"]?.doubleValue ?? 0)
                + 9 * (item["fatPer100g"]?.doubleValue ?? 0)
            if kcal > 20, abs(kcal - fromMacros) / kcal > Self.labelEnergyTolerance {
                problems.append("\(name): \(Int(kcal)) kcal doesn't match its protein, carbs "
                                + "and fat (about \(Int(fromMacros.rounded())) kcal)")
            }
        }
        guard !problems.isEmpty else { return }
        throw AssistantToolError.malformedArguments(
            tool: tool.rawValue,
            detail: "label figures look misread - \(problems.joined(separator: "; ")). Read "
                + "the label again and send every value per 100 g (convert from per serving "
                + "if needed)")
    }

    /// Fibre, sugar alcohols and rounding make real labels differ from 4/4/9
    /// a little, but rarely by this much.
    static let labelEnergyTolerance = 0.3

    /// Swaps the model's per-100 g guess for the app's own figures wherever the
    /// nutrition data layer knows the food: the user's saved products first,
    /// then MyFCD, then the generic table (spec section 23). Unknown foods keep
    /// the - already sanity-checked - estimate, marked as an estimate.
    static func resolve(_ item: IngredientDraft, with repository: NutritionRepository) -> IngredientDraft {
        // A nutrition label - typed, photographed or the brand's own - beats
        // any database row, so those figures are never replaced.
        guard !item.provenance.isDeclared else { return item }
        guard let hit = repository.lookup(canonicalID: nil, name: item.name) else { return item }
        var resolved = item
        resolved.nutritionPerServing = hit.nutritionPer100g
        resolved.canonicalID = hit.canonicalID
        resolved.provenance = hit.provenance
        return resolved
    }

    private func proposeEdit(call: AssistantToolCall) throws -> PendingAssistantWrite {
        let id = try AssistantArgumentParser.parseEntryID(call.arguments["id"])

        // The entry may have been deleted in another session since the model
        // last saw the context (spec section 34).
        guard let entry = context.fetchEntry(id: id) else {
            throw AssistantToolError.entryNotFound(id: id.uuidString)
        }

        // Start from the entry as it is and apply only the fields provided, so
        // an edit that mentions one field does not blank the rest.
        var draft = FoodEntryDraft(entry: entry)
        let arguments = call.arguments

        if let name = arguments["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            draft.name = name
        }
        if let consumedAt = AssistantArgumentParser.parseDate(arguments["consumedAt"]) {
            draft.consumedAt = consumedAt
        }

        let repository = NutritionRepository(context: context)
        try AssistantArgumentParser.checkItems(arguments["items"], tool: .editFoodEntry)
        try Self.checkLabelFigures(arguments["items"], tool: .editFoodEntry)
        if let items = AssistantArgumentParser.parseItems(arguments["items"], resolve: {
            Self.resolve($0, with: repository)
        }) {
            try Self.requireNutrition(items, tool: .editFoodEntry)
            // A new component list - e.g. with an ingredient the user forgot -
            // replaces what's in the food, and the totals follow from it.
            AssistantArgumentParser.setComponents(Self.keepingKnownFigures(items, from: draft),
                                                  on: &draft)
        } else {
            applyAmountAndNutrition(arguments, to: &draft)
        }

        return PendingAssistantWrite(id: call.id, tool: .editFoodEntry,
                                     action: .edit(entryID: id, draft: draft,
                                                   originalName: entry.name))
    }

    /// Components that were already in the entry keep their identity and
    /// figures - which may have been corrected by hand - and take only the new
    /// amount. Everything else comes from the nutrition database as usual.
    static func keepingKnownFigures(_ items: [IngredientDraft],
                                    from draft: FoodEntryDraft) -> [IngredientDraft] {
        var existing = draft.ingredients.filter { $0.unit == .gram }
        return items.map { item in
            // Newly given label figures replace whatever was there before.
            guard !item.provenance.isDeclared else { return item }
            let key = item.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard let index = existing.firstIndex(where: {
                $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key
            }) else { return item }
            var kept = existing.remove(at: index)
            kept.quantity = item.quantity
            return kept
        }
    }

    /// An edit without a component list: amount, unit and - for a simple
    /// food only - the nutrition figures.
    private func applyAmountAndNutrition(_ arguments: [String: JSONValue],
                                         to draft: inout FoodEntryDraft) {
        if let quantity = arguments["quantity"]?.doubleValue, quantity > 0 {
            draft.quantity = quantity
        }
        if let servingSize = arguments["servingSize"]?.doubleValue, servingSize > 0 {
            draft.servingSize = servingSize
        }
        if let unit = AssistantArgumentParser.parseUnit(arguments["unit"]) {
            draft.unit = unit
        }

        // Nutrition fields are only touched for a simple food: rewriting the
        // parent's figures on a composite food would silently detach it from its
        // ingredients.
        if !draft.isComposite {
            var nutrition = draft.nutritionPerServing
            if let value = arguments["calories"]?.doubleValue { nutrition.calories = value }
            if let value = arguments["protein"]?.doubleValue { nutrition.protein = value }
            if let value = arguments["carbs"]?.doubleValue { nutrition.carbs = value }
            if let value = arguments["fat"]?.doubleValue { nutrition.fat = value }
            if let value = arguments["fibre"]?.doubleValue { nutrition.fibre = value }
            draft.nutritionPerServing = nutrition.sanitised
        }
    }

    private func proposeDelete(call: AssistantToolCall) throws -> PendingAssistantWrite {
        let id = try AssistantArgumentParser.parseEntryID(call.arguments["id"])
        guard let entry = context.fetchEntry(id: id) else {
            throw AssistantToolError.entryNotFound(id: id.uuidString)
        }
        return PendingAssistantWrite(id: call.id, tool: .deleteFoodEntry,
                                     action: .delete(entryID: id,
                                                     name: entry.name,
                                                     calories: entry.total.calories))
    }

    // MARK: Commit (the only method that writes)

    /// Applies a write the user explicitly confirmed. Returns the JSON result to
    /// send back to the model.
    @discardableResult
    func commit(_ write: PendingAssistantWrite) throws -> String {
        switch write.action {
        case .add(let draft):
            let entry = draft.makeEntry()
            context.insert(entry)
            try context.save()
            // The app's own totals, so the model quotes these rather than a
            // figure it made up.
            struct Added: Encodable {
                let status = "added"
                let id: String
                let name: String
                let calories: Double
                let protein: Double
                let carbs: Double
                let fat: Double
            }
            let total = entry.total
            return try encode(Added(id: entry.id.uuidString, name: entry.name,
                                    calories: total.calories.rounded(),
                                    protein: total.protein.rounded(),
                                    carbs: total.carbs.rounded(),
                                    fat: total.fat.rounded()))

        case .edit(let entryID, let draft, _):
            guard let entry = context.fetchEntry(id: entryID) else {
                throw AssistantToolError.entryNotFound(id: entryID.uuidString)
            }
            draft.apply(to: entry)
            try context.save()
            return try encode(["status": "updated",
                               "id": entry.id.uuidString,
                               "name": entry.name])

        case .delete(let entryID, let name, _):
            guard let entry = context.fetchEntry(id: entryID) else {
                throw AssistantToolError.entryNotFound(id: entryID.uuidString)
            }
            if let photoPath = entry.photoPath {
                ImageStore.delete(relativePath: photoPath)
            }
            context.delete(entry)
            try context.save()
            return try encode(["status": "deleted", "name": name])
        }
    }

    /// Result sent back to the model when the user declines
    /// (spec section 34).
    func declinedResult(for write: PendingAssistantWrite) -> String {
        let action: String = switch write.action {
        case .add: "add"
        case .edit: "edit"
        case .delete: "delete"
        }
        return (try? encode([
            "status": "declined",
            "detail": "The user declined the proposed \(action). Nothing was changed. "
                + "Do not retry unless they ask again."
        ])) ?? "{\"status\":\"declined\"}"
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
