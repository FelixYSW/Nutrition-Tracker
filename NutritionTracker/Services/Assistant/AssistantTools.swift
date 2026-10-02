import Foundation

/// The five tools exposed to the model (spec section 29A).
///
/// Read tools execute immediately. Write tools never commit on their own: they
/// produce a proposal that the user must confirm, exactly as the photo pipeline
/// requires a review step.
enum AssistantTool: String, CaseIterable, Sendable {
    case addFoodEntry
    case editFoodEntry
    case deleteFoodEntry
    case queryEntries
    case getTrends

    /// Whether executing this tool changes the database.
    var isWrite: Bool {
        switch self {
        case .addFoodEntry, .editFoodEntry, .deleteFoodEntry: true
        case .queryEntries, .getTrends: false
        }
    }

    var description: String {
        switch self {
        case .addFoodEntry:
            "Propose adding a food entry to the user's log. Requires the user to "
                + "confirm before it is saved. Provide nutrition per serving."
        case .editFoodEntry:
            "Propose changing an existing food entry, identified by its id. "
                + "Requires user confirmation."
        case .deleteFoodEntry:
            "Propose deleting an existing food entry by id. Requires user confirmation."
        case .queryEntries:
            "Read the user's logged food entries within a date range. Read-only."
        case .getTrends:
            "Read aggregated calorie and macro trends. Read-only."
        }
    }

    /// JSON Schema for the tool's arguments.
    ///
    /// Built with typed helpers rather than nested literals: a literal mixing
    /// value types (e.g. a string next to an array) cannot be type-inferred.
    var inputSchema: [String: Any] {
        let units = ServingUnit.allCases.map(\.rawValue)
        switch self {
        case .addFoodEntry:
            let ingredient = Self.object([
                "name": Self.field("string"),
                "quantity": Self.field("number"),
                "servingSize": Self.field("number"),
                "unit": Self.field("string", allowed: units),
                "calories": Self.field("number"),
                "protein": Self.field("number"),
                "carbs": Self.field("number"),
                "fat": Self.field("number"),
                "fibre": Self.field("number")
            ], required: ["name", "quantity"])

            return Self.object([
                "name": Self.field("string", "Descriptive food name, e.g. \"Nasi Lemak\"."),
                "quantity": Self.field("number", "How much was eaten."),
                "servingSize": Self.field("number", "Serving size the nutrition refers to."),
                "unit": Self.field("string", allowed: units),
                "calories": Self.field("number", "Kilocalories per serving."),
                "protein": Self.field("number", "Grams per serving."),
                "carbs": Self.field("number", "Grams per serving."),
                "fat": Self.field("number", "Grams per serving."),
                "fibre": Self.field("number", "Grams per serving."),
                "consumedAt": Self.field("string", "ISO 8601 timestamp. Omit for now."),
                "ingredients": Self.array(of: ingredient,
                                          "Optional ingredient breakdown for a composite food.")
            ], required: ["name"])

        case .editFoodEntry:
            return Self.object([
                "id": Self.field("string", "UUID of the entry to change."),
                "name": Self.field("string"),
                "quantity": Self.field("number"),
                "servingSize": Self.field("number"),
                "unit": Self.field("string", allowed: units),
                "calories": Self.field("number"),
                "protein": Self.field("number"),
                "carbs": Self.field("number"),
                "fat": Self.field("number"),
                "fibre": Self.field("number"),
                "consumedAt": Self.field("string", "ISO 8601 timestamp.")
            ], required: ["id"])

        case .deleteFoodEntry:
            return Self.object([
                "id": Self.field("string", "UUID of the entry to delete.")
            ], required: ["id"])

        case .queryEntries:
            return Self.object([
                "startDate": Self.field("string", "ISO 8601 date. Defaults to today."),
                "endDate": Self.field("string", "ISO 8601 date, exclusive. Defaults to tomorrow.")
            ], required: [])

        case .getTrends:
            return Self.object([
                "timeframe": Self.field("string", "Aggregation scale.",
                                        allowed: TrendScale.allCases.map(\.rawValue))
            ], required: ["timeframe"])
        }
    }

    private static func field(_ type: String, _ description: String? = nil,
                              allowed: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": type]
        if let description { schema["description"] = description }
        if let allowed { schema["enum"] = allowed }
        return schema
    }

    private static func array(of items: [String: Any], _ description: String) -> [String: Any] {
        ["type": "array", "description": description, "items": items]
    }

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        // Omitted when empty: some providers (Gemini among them) are strict
        // about function schemas, and an absent list means the same thing.
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
}

/// A tool call as requested by the model.
struct AssistantToolCall: Identifiable, Equatable, Sendable {
    /// Provider-assigned call id, echoed back with the result.
    let id: String
    let tool: AssistantTool
    /// Raw decoded arguments.
    let arguments: [String: JSONValue]
}

/// A write the assistant wants to make, awaiting explicit confirmation
/// (spec section 29A).
///
/// This type is the confirmation gate: nothing in the assistant flow can reach
/// the database except by the user accepting one of these.
struct PendingAssistantWrite: Identifiable, Equatable, Sendable {
    let id: String
    let tool: AssistantTool
    let action: Action

    enum Action: Equatable, Sendable {
        case add(FoodEntryDraft)
        case edit(entryID: UUID, draft: FoodEntryDraft, originalName: String)
        case delete(entryID: UUID, name: String, calories: Double)
    }

    var confirmationTitle: String {
        switch action {
        case .add: "Add this food?"
        case .edit: "Update this food?"
        case .delete: "Delete this food?"
        }
    }

    var confirmButtonTitle: String {
        switch action {
        case .add: "Add"
        case .edit: "Update"
        case .delete: "Delete"
        }
    }

    var isDestructive: Bool {
        if case .delete = action { return true }
        return false
    }
}

// MARK: - Tool-call argument parsing

enum AssistantToolError: LocalizedError, Equatable {
    case unknownTool(name: String)
    case malformedArguments(tool: String, detail: String)
    case entryNotFound(id: String)
    case invalidIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "The assistant asked for an unknown tool (\"\(name)\")."
        case .malformedArguments(let tool, let detail):
            "The assistant sent unusable arguments for \(tool): \(detail)."
        case .entryNotFound(let id):
            "That food entry no longer exists (id \(id)). It may have been deleted already."
        case .invalidIdentifier(let value):
            "\"\(value)\" is not a valid entry identifier."
        }
    }
}

/// Minimal JSON value, so tool arguments can be decoded without a bespoke type
/// per tool and without `Any` leaking through the app.
enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    /// Tolerates a number arriving as a string, which models do often enough
    /// that rejecting it would be needlessly brittle.
    var doubleValue: Double? {
        switch self {
        case .number(let value): value.isFinite ? value : nil
        case .string(let value): Double(value.replacingOccurrences(of: ",", with: "."))
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let values) = self { return values }
        return nil
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Number before Bool: some Foundation JSON decoders will read 0/1 as a
        // Bool, which would turn `"quantity": 1` into `true`.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Turns raw tool arguments into validated drafts.
///
/// Every number is bounds-checked and every enum value verified, because a
/// hallucinated field or an out-of-range value must produce a clear error rather
/// than a corrupt entry (spec section 34).
enum AssistantArgumentParser {

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ value: JSONValue?) -> Date? {
        guard let string = value?.stringValue else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        // Also accept a bare date, which models produce frequently.
        let dateOnly = DateFormatter()
        dateOnly.calendar = .autoupdatingCurrent
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: string)
    }

    static func parseUnit(_ value: JSONValue?) -> ServingUnit? {
        guard let raw = value?.stringValue?.lowercased() else { return nil }
        return ServingUnit(rawValue: raw)
    }

    static func nutrition(from arguments: [String: JSONValue]) -> Nutrition {
        Nutrition(calories: arguments["calories"]?.doubleValue ?? 0,
                  protein: arguments["protein"]?.doubleValue ?? 0,
                  carbs: arguments["carbs"]?.doubleValue ?? 0,
                  fat: arguments["fat"]?.doubleValue ?? 0,
                  fibre: arguments["fibre"]?.doubleValue ?? 0).sanitised
    }

    /// Builds a draft for `addFoodEntry`.
    static func parseAdd(arguments: [String: JSONValue]) throws -> FoodEntryDraft {
        guard let name = arguments["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw AssistantToolError.malformedArguments(
                tool: AssistantTool.addFoodEntry.rawValue, detail: "a food name is required")
        }

        let unit = parseUnit(arguments["unit"]) ?? .serving
        let quantity = arguments["quantity"]?.doubleValue ?? 1
        let servingSize = arguments["servingSize"]?.doubleValue ?? 1

        guard quantity > 0 else {
            throw AssistantToolError.malformedArguments(
                tool: AssistantTool.addFoodEntry.rawValue, detail: "quantity must be positive")
        }
        guard servingSize > 0 else {
            throw AssistantToolError.malformedArguments(
                tool: AssistantTool.addFoodEntry.rawValue, detail: "serving size must be positive")
        }

        let ingredients = (arguments["ingredients"]?.arrayValue ?? []).compactMap {
            parseIngredient($0.objectValue ?? [:])
        }

        var draft = FoodEntryDraft(name: name,
                                   consumedAt: parseDate(arguments["consumedAt"]) ?? .now,
                                   quantity: quantity,
                                   servingSize: servingSize,
                                   unit: unit,
                                   nutritionPerServing: nutrition(from: arguments),
                                   ingredients: ingredients,
                                   source: .assistant)

        // A composite food derives its nutrition from its children, so the
        // parent's own figures are cleared to avoid double-counting.
        if !draft.ingredients.isEmpty {
            draft.nutritionPerServing = .zero
            draft.quantity = max(1, quantity)
            draft.servingSize = 1
            draft.unit = .serving
        }

        return draft
    }

    static func parseIngredient(_ arguments: [String: JSONValue]) -> IngredientDraft? {
        guard let name = arguments["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        let quantity = arguments["quantity"]?.doubleValue ?? 0
        let servingSize = arguments["servingSize"]?.doubleValue ?? 100
        guard quantity > 0, servingSize > 0 else { return nil }

        return IngredientDraft(name: name,
                               quantity: quantity,
                               servingSize: servingSize,
                               unit: parseUnit(arguments["unit"]) ?? .gram,
                               nutritionPerServing: nutrition(from: arguments),
                               provenance: .modelEstimate)
    }

    static func parseEntryID(_ value: JSONValue?) throws -> UUID {
        guard let raw = value?.stringValue else {
            throw AssistantToolError.malformedArguments(tool: "editFoodEntry",
                                                        detail: "an entry id is required")
        }
        guard let uuid = UUID(uuidString: raw) else {
            throw AssistantToolError.invalidIdentifier(raw)
        }
        return uuid
    }

    static func parseTrendScale(_ value: JSONValue?) -> TrendScale {
        guard let raw = value?.stringValue?.lowercased(),
              let scale = TrendScale(rawValue: raw) else {
            return .daily
        }
        return scale
    }
}
