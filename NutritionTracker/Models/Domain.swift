import Foundation

// MARK: - Enumerations

enum FoodSource: String, Codable, CaseIterable, Sendable {
    case manual, photoAI, barcode, assistant

    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .photoAI: "Photo AI"
        case .barcode: "Barcode"
        case .assistant: "Assistant"
        }
    }

    var symbolName: String {
        switch self {
        case .manual: "square.and.pencil"
        case .photoAI: "camera.viewfinder"
        case .barcode: "barcode.viewfinder"
        case .assistant: "sparkles"
        }
    }
}

enum ServingUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case serving, piece, gram, millilitre, scoop, tablespoon, teaspoon

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .serving: "srv"
        case .piece: "pc"
        case .gram: "g"
        case .millilitre: "ml"
        case .scoop: "scoop"
        case .tablespoon: "tbsp"
        case .teaspoon: "tsp"
        }
    }

    var displayName: String {
        switch self {
        case .serving: "Serving"
        case .piece: "Piece"
        case .gram: "Gram"
        case .millilitre: "Millilitre"
        case .scoop: "Scoop"
        case .tablespoon: "Tablespoon"
        case .teaspoon: "Teaspoon"
        }
    }

    /// Increment applied by a single minus/plus press (spec section 11).
    var step: Double {
        switch self {
        case .piece: 1
        case .gram: 10
        case .millilitre: 25
        case .scoop: 0.5
        case .serving: 0.5
        case .tablespoon, .teaspoon: 1
        }
    }

    /// Coarser increment for bulk units, offered as a secondary control.
    var coarseStep: Double {
        switch self {
        case .gram: 25
        case .millilitre: 50
        default: step
        }
    }

    /// Decimal places worth showing for a quantity in this unit.
    var fractionDigits: Int {
        switch self {
        case .gram, .millilitre, .piece: 0
        case .serving, .scoop, .tablespoon, .teaspoon: 1
        }
    }
}

enum BiologicalSex: String, Codable, CaseIterable, Identifiable, Sendable {
    case female, male
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum FitnessGoal: String, Codable, CaseIterable, Identifiable, Sendable {
    case loseWeight, recomposition, maintain, buildMuscle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .loseWeight: "Lose Weight"
        case .recomposition: "Lose Fat + Build Muscle"
        case .maintain: "Maintain"
        case .buildMuscle: "Build Muscle"
        }
    }

    var detail: String {
        switch self {
        case .loseWeight: "A moderate calorie deficit with high protein to protect lean mass."
        case .recomposition: "A small deficit with high protein, aiming to shift body composition."
        case .maintain: "Eating around maintenance to hold your current weight."
        case .buildMuscle: "A modest surplus to support training and muscle gain."
        }
    }
}

enum ActivityLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case sedentary, light, moderate, active, veryActive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sedentary: "Sedentary"
        case .light: "Lightly Active"
        case .moderate: "Moderately Active"
        case .active: "Active"
        case .veryActive: "Very Active"
        }
    }

    var detail: String {
        switch self {
        case .sedentary: "Desk job, little deliberate exercise."
        case .light: "Light exercise or walking 1-3 days a week."
        case .moderate: "Moderate exercise 3-5 days a week."
        case .active: "Hard exercise 6-7 days a week."
        case .veryActive: "Physical job or twice-daily training."
        }
    }

    /// Standard Mifflin-St Jeor activity multipliers. These already account for
    /// exercise, which is why strength/cardio session counts are stored for
    /// profile context only and never added again (spec section 6).
    var multiplier: Double {
        switch self {
        case .sedentary: 1.200
        case .light: 1.375
        case .moderate: 1.550
        case .active: 1.725
        case .veryActive: 1.900
        }
    }
}

/// The five tracked nutrients. Drives range logic, rings and charts generically
/// instead of repeating the same code five times.
enum Nutrient: String, CaseIterable, Identifiable, Sendable {
    case calories, protein, carbs, fat, fibre

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calories: "Calories"
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        case .fibre: "Fibre"
        }
    }

    var unitLabel: String {
        switch self {
        case .calories: "kcal"
        default: "g"
        }
    }

    /// Calories, protein, carbs and fat get rings on the Dashboard; fibre is secondary.
    var isPrimary: Bool { self != .fibre }
}

// MARK: - Nutrition value type

/// Nutrition payload, always expressed *per serving size*; callers scale it by
/// quantity. All nutrition arithmetic in the app happens here in Swift, never
/// inside a model (spec section 23).
struct Nutrition: Codable, Equatable, Sendable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fibre: Double = 0
    var sugar: Double = 0
    var sodium: Double = 0

    static let zero = Nutrition()

    init(calories: Double = 0, protein: Double = 0, carbs: Double = 0,
         fat: Double = 0, fibre: Double = 0, sugar: Double = 0, sodium: Double = 0) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fibre = fibre
        self.sugar = sugar
        self.sodium = sodium
    }

    subscript(nutrient: Nutrient) -> Double {
        switch nutrient {
        case .calories: calories
        case .protein: protein
        case .carbs: carbs
        case .fat: fat
        case .fibre: fibre
        }
    }

    static func + (lhs: Nutrition, rhs: Nutrition) -> Nutrition {
        Nutrition(calories: lhs.calories + rhs.calories,
                  protein: lhs.protein + rhs.protein,
                  carbs: lhs.carbs + rhs.carbs,
                  fat: lhs.fat + rhs.fat,
                  fibre: lhs.fibre + rhs.fibre,
                  sugar: lhs.sugar + rhs.sugar,
                  sodium: lhs.sodium + rhs.sodium)
    }

    static func * (lhs: Nutrition, factor: Double) -> Nutrition {
        guard factor.isFinite else { return .zero }
        return Nutrition(calories: lhs.calories * factor,
                         protein: lhs.protein * factor,
                         carbs: lhs.carbs * factor,
                         fat: lhs.fat * factor,
                         fibre: lhs.fibre * factor,
                         sugar: lhs.sugar * factor,
                         sodium: lhs.sodium * factor)
    }

    /// Guards against NaN/infinite/negative values arriving from an external API
    /// or a malformed model output (spec section 34).
    var isValid: Bool {
        [calories, protein, carbs, fat, fibre, sugar, sodium]
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }

    /// Clamps anything invalid rather than letting NaN propagate into the UI.
    var sanitised: Nutrition {
        func clean(_ value: Double) -> Double {
            guard value.isFinite, value >= 0 else { return 0 }
            return value
        }
        return Nutrition(calories: clean(calories), protein: clean(protein),
                         carbs: clean(carbs), fat: clean(fat), fibre: clean(fibre),
                         sugar: clean(sugar), sodium: clean(sodium))
    }

    /// Energy implied by the macros (4/4/9 kcal per gram), useful as a
    /// consistency check against a model-reported calorie figure.
    var energyFromMacros: Double { protein * 4 + carbs * 4 + fat * 9 }
}

// MARK: - Nutrient ranges (v2)

/// A target expressed as a band rather than a single figure.
///
/// BMR/TDEE formulas and macro guidelines carry real margins of error, so the
/// app never presents a single number the user must hit exactly (spec section 6).
/// Each bound records whether the user edited it, so a later recalculation can
/// respect manual overrides.
struct NutrientRange: Codable, Equatable, Sendable {
    var min: Double
    var max: Double
    var minManuallyModified: Bool
    var maxManuallyModified: Bool

    init(min: Double, max: Double,
         minManuallyModified: Bool = false,
         maxManuallyModified: Bool = false) {
        // Keep the band well-formed even if a caller passes the bounds inverted.
        let lower = Swift.min(min, max)
        let upper = Swift.max(min, max)
        self.min = Swift.max(0, lower)
        self.max = Swift.max(0, upper)
        self.minManuallyModified = minManuallyModified
        self.maxManuallyModified = maxManuallyModified
    }

    static let zero = NutrientRange(min: 0, max: 0)

    var midpoint: Double { (min + max) / 2 }
    var width: Double { max - min }
    var isManuallyModified: Bool { minManuallyModified || maxManuallyModified }

    /// Builds a band around a point estimate using a fractional margin.
    static func band(around point: Double, fraction: Double) -> NutrientRange {
        guard point.isFinite, point > 0, fraction.isFinite, fraction >= 0 else {
            return .zero
        }
        return NutrientRange(min: (point * (1 - fraction)).rounded(),
                             max: (point * (1 + fraction)).rounded())
    }

    /// Builds a band around a point estimate using a fixed absolute margin.
    static func band(around point: Double, margin: Double) -> NutrientRange {
        guard point.isFinite, point > 0, margin.isFinite, margin >= 0 else {
            return .zero
        }
        return NutrientRange(min: Swift.max(0, (point - margin).rounded()),
                             max: (point + margin).rounded())
    }

    /// Three-state classification. Values exactly at either bound count as
    /// in-range (spec section 35 calls for boundary tests).
    func state(consumed: Double) -> RangeState {
        guard max > 0 else { return .within }
        if consumed < min { return .under }
        if consumed > max { return .over }
        return .within
    }

    /// Ring fill fraction, scaled so 1.0 sits at the top of the band.
    func progress(consumed: Double) -> Double {
        guard max > 0 else { return 0 }
        return consumed / max
    }

    /// Where the in-range band sits on a 0...max ring track, for shading the
    /// "in range" zone on the ring itself (spec section 13).
    func bandFractions() -> (start: Double, end: Double) {
        guard max > 0 else { return (0, 0) }
        return (Swift.min(1, min / max), 1)
    }

    func withManualMin(_ value: Double) -> NutrientRange {
        NutrientRange(min: value, max: Swift.max(value, max),
                      minManuallyModified: true,
                      maxManuallyModified: maxManuallyModified)
    }

    func withManualMax(_ value: Double) -> NutrientRange {
        NutrientRange(min: Swift.min(min, value), max: value,
                      minManuallyModified: minManuallyModified,
                      maxManuallyModified: true)
    }
}

/// The three states a tracked nutrient can be in relative to its band.
///
/// "Under" is the expected state for most of the day and is deliberately not
/// treated as a failure (spec section 13).
enum RangeState: String, Equatable, Sendable {
    case under, within, over

    var isFlagged: Bool { self == .over }
}

/// A complete set of per-nutrient target bands.
struct NutritionTargetRanges: Codable, Equatable, Sendable {
    var calories: NutrientRange
    var protein: NutrientRange
    var carbs: NutrientRange
    var fat: NutrientRange
    var fibre: NutrientRange

    static let zero = NutritionTargetRanges(calories: .zero, protein: .zero,
                                            carbs: .zero, fat: .zero, fibre: .zero)

    subscript(nutrient: Nutrient) -> NutrientRange {
        get {
            switch nutrient {
            case .calories: calories
            case .protein: protein
            case .carbs: carbs
            case .fat: fat
            case .fibre: fibre
            }
        }
        set {
            switch nutrient {
            case .calories: calories = newValue
            case .protein: protein = newValue
            case .carbs: carbs = newValue
            case .fat: fat = newValue
            case .fibre: fibre = newValue
            }
        }
    }

    var anyManuallyModified: Bool {
        Nutrient.allCases.contains { self[$0].isManuallyModified }
    }

    /// Room left to the top of each band, floored at zero. This is what the
    /// assistant uses to answer "what should I eat with what I have left".
    func remaining(consumed: Nutrition) -> Nutrition {
        Nutrition(calories: Swift.max(0, calories.max - consumed.calories),
                  protein: Swift.max(0, protein.max - consumed.protein),
                  carbs: Swift.max(0, carbs.max - consumed.carbs),
                  fat: Swift.max(0, fat.max - consumed.fat),
                  fibre: Swift.max(0, fibre.max - consumed.fibre))
    }

    /// What is still needed to reach the *bottom* of each band.
    func neededToReachMinimum(consumed: Nutrition) -> Nutrition {
        Nutrition(calories: Swift.max(0, calories.min - consumed.calories),
                  protein: Swift.max(0, protein.min - consumed.protein),
                  carbs: Swift.max(0, carbs.min - consumed.carbs),
                  fat: Swift.max(0, fat.min - consumed.fat),
                  fibre: Swift.max(0, fibre.min - consumed.fibre))
    }
}
