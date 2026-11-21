import Foundation

/// Every food the user has logged, merged by name: "Nasi lemak" eaten five
/// times is one record with five entries behind it. Nothing is stored for
/// this - it is built from the food log, so it can never drift from it.
struct FoodRecord: Identifiable {
    /// The normalised name.
    let id: String
    /// The name as it was last written.
    let name: String
    /// Newest first. Never empty.
    let entries: [FoodEntry]

    var latest: FoodEntry { entries[0] }
    var timesLogged: Int { entries.count }
    var lastEaten: Date { latest.consumedAt }

    /// What the latest entry came to, with the portion that was eaten.
    var latestTotal: Nutrition { latest.total }

    /// Average calories over every time it was logged.
    var averageCalories: Double {
        entries.reduce(0) { $0 + $1.total.calories } / Double(max(1, entries.count))
    }
}

enum FoodLibrarySort: String, CaseIterable, Identifiable {
    case recent, mostLogged, name

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recent: "Recent"
        case .mostLogged: "Most logged"
        case .name: "A-Z"
        }
    }
}

enum FoodLibrary {

    /// "  Nasi  Lemak " and "nasi lemak" are the same food.
    static func key(for name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func records(from entries: [FoodEntry]) -> [FoodRecord] {
        let sorted = entries.sorted { $0.consumedAt > $1.consumedAt }
        let groups = Dictionary(grouping: sorted) { key(for: $0.name) }
        return groups.compactMap { key, entries -> FoodRecord? in
            guard !key.isEmpty, let first = entries.first else { return nil }
            return FoodRecord(id: key,
                              name: first.name.trimmingCharacters(in: .whitespacesAndNewlines),
                              entries: entries)
        }
    }

    /// Records whose name, or an ingredient's name, contains every word typed.
    static func filter(_ records: [FoodRecord], query: String) -> [FoodRecord] {
        let words = key(for: query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return records }
        return records.filter { record in
            let haystack = ([record.id] + record.latest.ingredients.map { key(for: $0.name) })
                .joined(separator: " ")
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func sorted(_ records: [FoodRecord], by order: FoodLibrarySort) -> [FoodRecord] {
        switch order {
        case .recent:
            records.sorted { $0.lastEaten > $1.lastEaten }
        case .mostLogged:
            records.sorted {
                $0.timesLogged != $1.timesLogged ? $0.timesLogged > $1.timesLogged
                    : $0.lastEaten > $1.lastEaten
            }
        case .name:
            records.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}
