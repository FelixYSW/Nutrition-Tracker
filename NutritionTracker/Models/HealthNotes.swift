import Foundation

/// One health condition the assistant takes into account, usually read off a
/// check-up report: e.g. prediabetes with "HbA1c 6.1% (Oct 2026)" and
/// guidance like "At most 1 banana a day".
struct HealthNote: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// "Prediabetes", "High uric acid".
    var condition: String
    /// The measured values and their date, as on the report.
    var details: String
    /// Plain rules the assistant applies when logging and suggesting food.
    var guidance: [String]
    var updatedAt = Date.now
}

/// Keeps the user's health notes on this iPhone only.
///
/// UserDefaults rather than SwiftData, so the shipping database schema doesn't
/// change. Cleared by "Delete all data".
///
/// Not tied to the main actor: UserDefaults is safe to use from any thread,
/// and the assistant's context builder reads the notes from a default
/// argument, which Swift evaluates outside the main actor.
final class HealthNotesStore: @unchecked Sendable {
    static let shared = HealthNotesStore()

    private let defaults: UserDefaults
    private let key = "healthNotes.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var notes: [HealthNote] {
        guard let data = defaults.data(forKey: key),
              let notes = try? JSONDecoder().decode([HealthNote].self, from: data) else { return [] }
        return notes
    }

    func save(_ notes: [HealthNote]) {
        if notes.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(notes) {
            defaults.set(data, forKey: key)
        }
    }

    func delete(id: UUID) {
        save(notes.filter { $0.id != id })
    }

    func deleteAll() {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Changes the assistant can propose

/// New profile values from the assistant; nil fields stay as they are.
struct ProfileUpdate: Codable, Equatable, Sendable {
    var weightKg: Double?
    var heightCm: Double?
    var targetWeightKg: Double?
    var goal: FitnessGoal?
    var activity: ActivityLevel?
    /// "Weight 100 -> 97 kg", for the card.
    var lines: [String]
    /// Why, in one line, e.g. "From your check-up on 20 Oct".
    var reason: String?
}

/// New bounds for some daily ranges. Saved as edited by hand, so a later
/// profile change doesn't recalculate them away.
struct RangesUpdate: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        /// `Nutrient.rawValue`.
        var nutrient: String
        var old: NutrientRange
        var new: NutrientRange
    }
    var changes: [Change]
    var reason: String?
}

/// The complete set of health notes to keep, replacing what was saved.
struct HealthNotesUpdate: Codable, Equatable, Sendable {
    var notes: [HealthNote]
    var reason: String?
}
