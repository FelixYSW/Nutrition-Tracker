import Foundation
import SwiftData

/// Outcome of handing a tool call to the executor.
enum AssistantToolOutcome: Equatable, Sendable {
    /// A read-only tool ran; the JSON string goes back to the model.
    case result(String)
    /// A write was proposed and is waiting for the user. Nothing has been
    /// written yet.
    case awaitingConfirmation(PendingAssistantWrite)
    /// The tool call could not be used at all.
    case failure(String)

    var isWriteProposal: Bool {
        if case .awaitingConfirmation = self { return true }
        return false
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
            case .addFoodEntry:
                return .awaitingConfirmation(try proposeAdd(call: call))
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

    private func getTrends(arguments: [String: JSONValue]) throws -> String {
        let scale = AssistantArgumentParser.parseTrendScale(arguments["timeframe"])
        let now = Date.now

        let intervals = TrendAggregator.intervals(scale: scale, endingOn: now,
                                                   count: scale.bucketCount,
                                                   calendar: calendar)
        guard let windowStart = intervals.first?.start,
              let windowEnd = intervals.last?.end else {
            return try encode(["buckets": [String]()])
        }

        let entries = context.fetchEntries(from: windowStart, to: windowEnd)
        let buckets = TrendAggregator.buckets(entries: entries, scale: scale,
                                               endingOn: now, calendar: calendar)
        let ranges = context.loadNutritionTarget()?.ranges

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
            }
            let timeframe: String
            let plots: String
            let buckets: [Bucket]
        }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
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
                             states: states)
            })

        return try encode(payload)
    }

    // MARK: Write proposals (still no writes)

    private func proposeAdd(call: AssistantToolCall) throws -> PendingAssistantWrite {
        let draft = try AssistantArgumentParser.parseAdd(arguments: call.arguments)
        return PendingAssistantWrite(id: call.id, tool: .addFoodEntry, action: .add(draft))
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
        if let quantity = arguments["quantity"]?.doubleValue, quantity > 0 {
            draft.quantity = quantity
        }
        if let servingSize = arguments["servingSize"]?.doubleValue, servingSize > 0 {
            draft.servingSize = servingSize
        }
        if let unit = AssistantArgumentParser.parseUnit(arguments["unit"]) {
            draft.unit = unit
        }
        if let consumedAt = AssistantArgumentParser.parseDate(arguments["consumedAt"]) {
            draft.consumedAt = consumedAt
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

        return PendingAssistantWrite(id: call.id, tool: .editFoodEntry,
                                     action: .edit(entryID: id, draft: draft,
                                                   originalName: entry.name))
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
            return try encode(["status": "added",
                               "id": entry.id.uuidString,
                               "name": entry.name])

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
