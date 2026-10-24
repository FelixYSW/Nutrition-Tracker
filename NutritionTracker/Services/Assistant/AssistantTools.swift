import Foundation

/// The tools exposed to the model (spec section 29A).
///
/// Read tools execute immediately. Write tools never commit on their own: they
/// produce a proposal that the user must confirm, exactly as the photo pipeline
/// requires a review step.
enum AssistantTool: String, CaseIterable, Codable, Sendable {
    case addFoodEntry
    case repeatFoodEntry
    case editFoodEntry
    case deleteFoodEntry
    case queryEntries
    case getTrends
    case findFoodNearby
    case lookUpProductNutrition
    case findProducts
    case calculateNutrition
    case updateProfile
    case updateDailyRanges
    case saveHealthNotes

    /// Tools answered from a live web search rather than the local database.
    var usesWebSearch: Bool {
        self == .findFoodNearby || self == .lookUpProductNutrition || self == .findProducts
    }

    /// Whether executing this tool changes the database.
    var isWrite: Bool {
        switch self {
        case .addFoodEntry, .repeatFoodEntry, .editFoodEntry, .deleteFoodEntry,
             .updateProfile, .updateDailyRanges, .saveHealthNotes: true
        case .queryEntries, .getTrends, .findFoodNearby, .lookUpProductNutrition, .findProducts,
             .calculateNutrition:
            false
        }
    }

    var description: String {
        switch self {
        case .addFoodEntry:
            "Propose logging a food the user says they ate or asks to log - never "
                + "just because they shared a photo or asked what to eat. Shown to the "
                + "user as a confirmation card; nothing is saved until they confirm. "
                + "Put each separate dish, drink or snack in foods as its own entry - "
                + "each becomes its own card (a banana, a yoghurt and a protein shake are 3 "
                + "foods, not one). To amend an open card, give that food its cardID as "
                + "replacesCard. "
                + "List every component separately with the grams actually eaten - "
                + "including cooking oil, sauces and drinks - and never give a total for "
                + "the whole dish: the app works out the totals itself from its nutrition "
                + "database. For each component also give your best per-100 g estimate; "
                + "it is only used when the database has no match. Not for something the "
                + "user forgot from a meal already logged - edit that entry instead."
        case .repeatFoodEntry:
            "Propose logging a food from the user's log again, exactly as it was - every "
                + "ingredient, portion and figure copied by the app. Use it whenever the user "
                + "says they had the same food as before (\"the same overnight oats as on the "
                + "23rd\", \"my usual breakfast\", \"same as yesterday\"): find the entry with "
                + "queryEntries and give its id, and when they ate it this time. Never "
                + "rebuild such a food with addFoodEntry. If something changed (\"but with 2 "
                + "scoops of whey\"), repeat it first, then change that item with "
                + "editFoodEntry once it's saved. Shown as a confirmation card."
        case .editFoodEntry:
            "Propose changing an existing food entry, identified by its id - "
                + "including when the user mentions something they forgot that was part "
                + "of a logged meal. To change what is in it, send items: the complete "
                + "new component list with grams (every existing ingredient plus the "
                + "added or changed ones), never a total. The app recalculates the "
                + "nutrition. Requires user confirmation."
        case .deleteFoodEntry:
            "Propose deleting an existing food entry by id. Requires user confirmation."
        case .queryEntries:
            "Read the user's logged food entries within a date range. Read-only."
        case .getTrends:
            "Read the user's intake over a longer period - days, weeks or months - with "
                + "averages, how many days each nutrient was under, within or over its range, "
                + "and weekday vs weekend averages. Use it for any question about this week, "
                + "this month, trends, progress or habits. Read-only."
        case .findFoodNearby:
            "Search the web for places to eat and their menus and prices - around the "
                + "user's current location, or in an area they name. Returns a summary with "
                + "sources."
        case .updateProfile:
            "Propose changing the user's profile: weight, height, target weight, goal or "
                + "activity level - e.g. a new weigh-in, or a goal changed on a doctor's "
                + "advice. Their daily ranges are recalculated from it (ranges they set by "
                + "hand are kept). Only the fields given change. Shown as a confirmation card."
        case .updateDailyRanges:
            "Propose new bounds for some daily ranges (calories, protein, carbs, fat, fibre) "
                + "- e.g. a lower carb maximum for prediabetes, or a higher fibre minimum. Give "
                + "only the nutrients that change, each with its new min and max. They are "
                + "kept as set even when the profile changes later. Shown as a confirmation card."
        case .saveHealthNotes:
            "Propose saving the user's health conditions and how they affect eating - "
                + "usually from a medical check-up report they shared. Send the complete list "
                + "to keep (it replaces what is saved, so include existing notes from the "
                + "context unless they no longer apply). Each note: the condition, the "
                + "measured values with their date, and a few short, specific rules for food "
                + "(e.g. \"At most 1 banana a day\", \"Limit prawns, organ meat and anchovies "
                + "- high purine\"). Shown as a confirmation card."
        case .calculateNutrition:
            "Work out kcal, protein, carbs and fat for foods with the app's own nutrition "
                + "data - exactly what a card would show - without logging anything. Call it "
                + "before quoting figures for specific foods, and quote its numbers. Read-only."
        case .lookUpProductNutrition:
            "Search the web for a branded or packaged product's published nutrition "
                + "facts (e.g. \"Farm Fresh full cream milk\", \"Milo 3in1\", \"Gardenia "
                + "Original Classic bread\"). Use it before logging any named brand or "
                + "chain item the user didn't give a label for, then log it with "
                + "nutritionSource \"brand\". Returns a summary with sources."
        case .findProducts:
            "Search the web for real products the user can buy - e.g. \"high protein bread "
                + "in Malaysia\", \"low sugar yoghurt\" - with their brand names and published "
                + "nutrition. Use it before recommending any specific brand or product: only "
                + "name products it returns. Returns a summary with sources."
        }
    }

    /// JSON Schema for the tool's arguments.
    ///
    /// Built with typed helpers rather than nested literals: a literal mixing
    /// value types (e.g. a string next to an array) cannot be type-inferred.
    var inputSchema: [String: Any] {
        let units = ServingUnit.allCases.map(\.rawValue)
        let replacesCard = Self.field("string", "Only when amending a card that is still "
                                      + "open: its cardID from the awaiting_user result. "
                                      + "Omit for a new card.")
        let item = Self.object([
            "name": Self.field("string", "One component, e.g. \"konjac knots\", \"egg\", "
                               + "\"cooking oil\". Plain food names match the database best."),
            "grams": Self.field("number", "Grams of this component actually eaten. "
                                + "Convert pieces to grams (e.g. 2 eggs = 100)."),
            "kcalPer100g": Self.field("number", "Per 100 g (or 100 ml) of this component: "
                                      + "from its nutrition label when there is one, "
                                      + "otherwise your estimate."),
            "proteinPer100g": Self.field("number", "Per 100 g."),
            "carbsPer100g": Self.field("number", "Per 100 g."),
            "fatPer100g": Self.field("number", "Per 100 g."),
            "fibrePer100g": Self.field("number", "Per 100 g."),
            "nutritionSource": Self.field(
                "string",
                "Where the per-100 g figures come from. \"label\": a nutrition table the user "
                    + "typed or photographed. \"brand\": the brand's published values found with "
                    + "lookUpProductNutrition. Both are used exactly as given, ahead of the app's "
                    + "database. \"saved\": copied from an entry already in the user's log "
                    + "(queryEntries lists each ingredient's figures), used exactly as given. "
                    + "\"estimate\" (default): your guess, replaced by the database "
                    + "when it knows the food.",
                allowed: ["label", "brand", "saved", "estimate"])
        ], required: ["name", "grams"])

        switch self {
        case .addFoodEntry:
            return addFoodsSchema(item: item, replacesCard: replacesCard)

        case .repeatFoodEntry:
            return Self.object([
                "id": Self.field("string", "UUID of the entry to log again, from queryEntries."),
                "consumedAt": Self.field("string", "When the user ate it this time, ISO 8601. "
                                         + "Omit for now."),
                "servings": Self.field("number", "How many of that entry they had this time; "
                                       + "1 (the default) is the same amount as before."),
                "replacesCard": replacesCard
            ], required: ["id"])

        case .editFoodEntry:
            return Self.object([
                "id": Self.field("string", "UUID of the entry to change."),
                "replacesCard": replacesCard,
                "name": Self.field("string"),
                "items": Self.array(of: item, "The complete updated component list: every "
                                    + "existing ingredient with its grams plus anything added "
                                    + "or changed. Replaces the entry's ingredients."),
                "quantity": Self.field("number", "How much of the entry was eaten, in its "
                                       + "unit. To log part of it, multiply the current "
                                       + "quantity by the share eaten (half of 1 serving = 0.5)."),
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
                "id": Self.field("string", "UUID of the entry to delete."),
                "replacesCard": replacesCard
            ], required: ["id"])

        case .queryEntries:
            return Self.object([
                "startDate": Self.field("string", "ISO 8601 date. Defaults to today."),
                "endDate": Self.field("string", "ISO 8601 date, inclusive: the last day to read (the same as startDate for one day). Defaults to today.")
            ], required: [])

        case .findProducts:
            return Self.object([
                "query": Self.field("string", "What to find, e.g. \"high protein wholemeal "
                                    + "bread\" or \"protein wraps\"."),
                "country": Self.field("string", "Where the user shops, e.g. \"Malaysia\"."),
                "goal": Self.field("string", "What matters most, e.g. \"most protein per "
                                   + "slice, under 100 kcal\".")
            ], required: ["query"])

        case .lookUpProductNutrition:
            return Self.object([
                "product": Self.field("string", "Brand and product as specific as the user "
                                      + "said, e.g. \"Farm Fresh Fresh Milk full cream\"."),
                "country": Self.field("string", "Where it's sold, if known, e.g. \"Malaysia\" - "
                                      + "recipes differ between countries.")
            ], required: ["product"])

        case .findFoodNearby:
            return Self.object([
                "place": Self.field("string", "Only when the user names an area, street, mall "
                                    + "or city in this message - exactly as they said it. "
                                    + "Omit it to search around their current location."),
                "budget": Self.field("string", "The user's budget if they gave one, e.g. "
                                     + "\"RM15 per person\"."),
                "preferences": Self.field("string", "What to look for, e.g. \"high protein, "
                                          + "under 600 kcal, halal\".")
            ], required: [])

        case .getTrends:
            return Self.object([
                "timeframe": Self.field("string", "daily: one row per day; weekly: one per "
                                        + "week; monthly: one per month.",
                                        allowed: TrendScale.allCases.map(\.rawValue)),
                "periods": Self.field("number", "How many days, weeks or months back, "
                                      + "including the current one (default 14 days, 8 weeks "
                                      + "or 6 months; at most \(Self.maxTrendPeriods)).")
            ], required: ["timeframe"])

        case .calculateNutrition:
            return addFoodsSchema(item: item, replacesCard: nil)

        case .updateProfile:
            return Self.object([
                "weightKg": Self.field("number", "Current weight in kg."),
                "heightCm": Self.field("number", "Height in cm."),
                "targetWeightKg": Self.field("number", "Goal weight in kg."),
                "goal": Self.field("string", allowed: FitnessGoal.allCases.map(\.rawValue)),
                "activityLevel": Self.field("string", allowed: ActivityLevel.allCases.map(\.rawValue)),
                "reason": Self.field("string", "One line saying why, shown on the card, e.g. "
                                     + "\"Weight from your check-up on 20 Oct\".")
            ], required: [])

        case .updateDailyRanges:
            let change = Self.object([
                "nutrient": Self.field("string", allowed: Nutrient.allCases.map(\.rawValue)),
                "min": Self.field("number", "New minimum (kcal for calories, g otherwise)."),
                "max": Self.field("number", "New maximum.")
            ], required: ["nutrient", "min", "max"])
            return Self.object([
                "ranges": Self.array(of: change, "Only the nutrients that change."),
                "reason": Self.field("string", "One line saying why, shown on the card.")
            ], required: ["ranges"])

        case .saveHealthNotes:
            let note = Self.object([
                "condition": Self.field("string", "e.g. \"Prediabetes\", \"High uric acid\"."),
                "details": Self.field("string", "The measured values and the report date, "
                                      + "e.g. \"HbA1c 6.1%, fasting glucose 6.3 mmol/L (20 Oct 2026)\"."),
                "guidance": Self.array(of: Self.field("string"),
                                       "Short, specific food rules for this condition.")
            ], required: ["condition", "guidance"])
            return Self.object([
                "notes": Self.array(of: note, "Every note to keep - replaces the saved list."),
                "reason": Self.field("string", "One line saying why, shown on the card.")
            ], required: ["notes"])
        }
    }

    /// Furthest back getTrends looks, in its own periods.
    static let maxTrendPeriods = 24

    /// Foods with their components, shared by addFoodEntry (which makes a card
    /// per food) and calculateNutrition (which only works the figures out).
    private func addFoodsSchema(item: [String: Any], replacesCard: [String: Any]?) -> [String: Any] {
        var foodFields: [String: Any] = [
            "name": Self.field("string", "Name of this one dish, drink or snack, e.g. "
                               + "\"Tomato egg with konjac\", \"Banana\"."),
            "items": Self.array(of: item, "Its components with their grams: one item for "
                                + "a simple food, several only for a mixed dish.")
        ]
        var fields: [String: Any] = [:]
        if let replacesCard {
            foodFields["consumedAt"] = Self.field("string", "Local ISO 8601 time it was eaten, "
                                                  + "e.g. 2026-10-14T23:45:00+08:00. Omit for "
                                                  + "just now.")
            foodFields["replacesCard"] = replacesCard
            fields["consumedAt"] = Self.field("string", "Local ISO 8601 time shared by all the "
                                              + "foods, if they were eaten together. Omit for now.")
        }
        let food = Self.object(foodFields, required: ["name", "items"])
        fields["foods"] = Self.array(of: food, replacesCard == nil
                                     ? "The foods to work out, one entry per dish, drink or snack."
                                     : "One entry per separate dish, drink or snack; each gets "
                                         + "its own card.")
        return Self.object(fields, required: ["foods"])
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
    /// Opaque provider data attached to the call. Not used by the OpenAI
    /// client; kept for chats saved by earlier versions.
    var extra: JSONValue? = nil
}

/// A write the assistant wants to make, awaiting explicit confirmation
/// (spec section 29A).
///
/// This type is the confirmation gate: nothing in the assistant flow can reach
/// the database except by the user accepting one of these.
struct PendingAssistantWrite: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let tool: AssistantTool
    let action: Action

    enum Action: Equatable, Codable, Sendable {
        case add(FoodEntryDraft)
        case edit(entryID: UUID, draft: FoodEntryDraft, originalName: String)
        case delete(entryID: UUID, name: String, calories: Double)
        case profile(ProfileUpdate)
        case ranges(RangesUpdate)
        case healthNotes(HealthNotesUpdate)
    }

    var confirmationTitle: String {
        switch action {
        case .add: "Add this food?"
        case .edit: "Update this food?"
        case .delete: "Delete this food?"
        case .profile: "Update your profile?"
        case .ranges: "Change your daily ranges?"
        case .healthNotes: "Save your health notes?"
        }
    }

    var confirmButtonTitle: String {
        switch action {
        case .add: "Add"
        case .edit: "Update"
        case .delete: "Delete"
        case .profile, .ranges: "Update"
        case .healthNotes: "Save"
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
        case .string(let value): Self.leadingNumber(in: value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    /// Models sometimes send numbers as text with a unit or a tilde: "250 g",
    /// "~30g", "1,5". Reads the number at the start and ignores the rest.
    static func leadingNumber(in text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "~≈ "))
            .replacingOccurrences(of: ",", with: ".")
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), value.isFinite else { return nil }
        return value
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

    /// Writes times in the user's own time zone (e.g. 2026-10-13T23:45:00+08:00),
    /// so the model reasons about "last night" in local time, not UTC.
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    /// Accepts a full timestamp with any offset, a local time without one
    /// ("2026-10-13T23:45"), or a bare date.
    static func parseDate(_ value: JSONValue?, timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
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

    /// Builds a draft for `addFoodEntry` from the model's component list.
    ///
    /// Every component becomes a gram-based ingredient whose values are per
    /// 100 g, so they scale correctly when the user changes the amount. The
    /// model's per-100 g figures are only provisional: `AssistantToolExecutor`
    /// replaces them with the app's nutrition database wherever it has a match.
    /// Whole-dish totals from the model are never used - they were the source of
    /// wildly wrong entries (e.g. a ~300 kcal plate logged as 1,000).
    static func parseAdd(arguments: [String: JSONValue],
                         resolve: (IngredientDraft) -> IngredientDraft = { $0 }) throws -> FoodEntryDraft {
        let tool = AssistantTool.addFoodEntry.rawValue
        guard let name = arguments["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw AssistantToolError.malformedArguments(tool: tool, detail: "a food name is required")
        }

        let items = (arguments["items"]?.arrayValue ?? []).compactMap {
            parseItem($0.objectValue ?? [:]).map(resolve)
        }
        guard !items.isEmpty else {
            // Say exactly what was wrong, so the model's retry gets it right.
            let raw = (arguments["items"]?.arrayValue ?? []).compactMap(\.objectValue)
            let detail = raw.isEmpty
                ? "items is empty - list each component with its grams"
                : "every item needs a \"grams\" number between 1 and "
                    + "\(Int(maximumItemGrams)): the weight eaten, not a count of servings "
                    + "(for one sandwich, its weight such as 180)"
            throw AssistantToolError.malformedArguments(tool: tool, detail: detail)
        }

        let consumedAt = parseDate(arguments["consumedAt"]) ?? .now
        // Food can't be eaten in the future; a time ahead of now is a date
        // the model worked out wrongly.
        if consumedAt.timeIntervalSinceNow > 15 * 60 {
            throw AssistantToolError.malformedArguments(
                tool: tool, detail: "consumedAt is in the future - use localDate, yesterdayDate "
                    + "and localTime from the context, or omit it for now")
        }
        var draft = FoodEntryDraft(name: name, consumedAt: consumedAt, source: .assistant)
        setComponents(items, on: &draft)
        return draft
    }

    /// The model's component list for an edit, or nil when the edit doesn't
    /// change what's in the food.
    static func parseItems(_ value: JSONValue?,
                           resolve: (IngredientDraft) -> IngredientDraft = { $0 }) -> [IngredientDraft]? {
        let items = (value?.arrayValue ?? []).compactMap {
            parseItem($0.objectValue ?? [:]).map(resolve)
        }
        return items.isEmpty ? nil : items
    }

    /// Shapes a draft around its components: one component is a simple food
    /// measured in grams; several make a composite dish of one serving whose
    /// nutrition comes from its parts.
    static func setComponents(_ items: [IngredientDraft], on draft: inout FoodEntryDraft) {
        if items.count == 1, let only = items.first {
            draft.quantity = only.quantity
            draft.servingSize = 100
            draft.unit = .gram
            draft.nutritionPerServing = only.nutritionPerServing
            draft.canonicalID = only.canonicalID
            draft.ingredients = []
        } else {
            draft.quantity = 1
            draft.servingSize = 1
            draft.unit = .serving
            draft.nutritionPerServing = .zero
            draft.canonicalID = nil
            draft.ingredients = items
        }
    }

    /// Largest believable mass for one component of one meal, in grams.
    static let maximumItemGrams: Double = 3000

    /// Every item must be usable. Dropping a bad one quietly and logging the
    /// rest loses food the user ate (a protein shake vanished this way), so
    /// the model is told which items to fix instead.
    static func checkItems(_ value: JSONValue?, tool: AssistantTool) throws {
        let raw = (value?.arrayValue ?? []).compactMap(\.objectValue)
        let unusable = raw.filter { parseItem($0) == nil }
            .map { $0["name"]?.stringValue ?? "an unnamed item" }
        guard !unusable.isEmpty else { return }
        throw AssistantToolError.malformedArguments(
            tool: tool.rawValue,
            detail: "these items have no usable \"grams\" (a weight between 1 and "
                + "\(Int(maximumItemGrams)), not a count): \(unusable.joined(separator: ", ")). "
                + "Send them again with their weight - nothing was logged")
    }

    /// The weight eaten. Models don't always use the schema's name for it, so
    /// the common alternatives are accepted too ("250 g" as text included).
    static func gramsValue(in arguments: [String: JSONValue]) -> Double? {
        for key in ["grams", "gram", "g", "weightGrams", "weight", "amountGrams", "ml"] {
            if let value = arguments[key]?.doubleValue { return value }
        }
        return nil
    }

    static func parseItem(_ arguments: [String: JSONValue]) -> IngredientDraft? {
        guard let name = arguments["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let grams = gramsValue(in: arguments),
              grams > 0, grams <= maximumItemGrams else {
            return nil
        }

        let figures = Nutrition(calories: arguments["kcalPer100g"]?.doubleValue ?? 0,
                                protein: arguments["proteinPer100g"]?.doubleValue ?? 0,
                                carbs: arguments["carbsPer100g"]?.doubleValue ?? 0,
                                fat: arguments["fatPer100g"]?.doubleValue ?? 0,
                                fibre: arguments["fibrePer100g"]?.doubleValue ?? 0)

        // Label and brand figures are the most accurate there are, so they are
        // kept as declared - only impossible values are capped. A "label" with
        // no figures at all is treated as a guess.
        let declared: NutritionProvenance? = switch arguments["nutritionSource"]?.stringValue?.lowercased() {
        case "label": .nutritionLabel
        case "brand": .brandPublished
        // Repeating something already logged: the same figures as before.
        case "saved": .localVerified
        default: nil
        }
        if let declared, figures.calories > 0 || figures.energyFromMacros > 0 {
            return IngredientDraft(name: name,
                                   quantity: grams.rounded(),
                                   servingSize: 100,
                                   unit: .gram,
                                   nutritionPerServing: declaredPer100g(figures),
                                   provenance: declared)
        }

        return IngredientDraft(name: name,
                               quantity: grams.rounded(),
                               servingSize: 100,
                               unit: .gram,
                               nutritionPerServing: plausiblePer100g(figures),
                               provenance: .modelEstimate)
    }

    /// Label figures as declared. Calories are only worked out from the
    /// macros when the label figure is missing, and nothing can exceed what
    /// 100 g can physically hold.
    static func declaredPer100g(_ label: Nutrition) -> Nutrition {
        var value = label.sanitised
        value.protein = min(value.protein, 100)
        value.carbs = min(value.carbs, 100)
        value.fat = min(value.fat, 100)
        value.fibre = min(value.fibre, 100)
        if value.calories <= 0 { value.calories = value.energyFromMacros.rounded() }
        value.calories = min(value.calories, 900)
        return value
    }

    /// Repairs a per-100 g estimate that can't be physically right.
    ///
    /// - Nothing exceeds pure fat (about 900 kcal/100 g), and macros can't
    ///   weigh more than the 100 g they're in.
    /// - When protein, carbs and fat are given, calories are checked against
    ///   them (4/4/9 kcal per gram). If the stated figure is more than 25% off,
    ///   the macro-derived value is used: the macros are usually the more
    ///   reliable half of a guess.
    static func plausiblePer100g(_ estimate: Nutrition) -> Nutrition {
        var value = estimate.sanitised
        value.protein = min(value.protein, 100)
        value.carbs = min(value.carbs, 100)
        value.fat = min(value.fat, 100)
        value.fibre = min(value.fibre, value.carbs > 0 ? value.carbs : 100)

        let fromMacros = value.energyFromMacros
        if fromMacros > 0 {
            let gap = abs(value.calories - fromMacros) / fromMacros
            if value.calories <= 0 || gap > 0.25 { value.calories = fromMacros.rounded() }
        }
        value.calories = min(value.calories, 900)
        return value
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
