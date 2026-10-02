import Foundation

/// Canonical food-label mapping (spec section 22).
///
/// Datasets disagree about names: FoodSeg103 says "rice", MF-150 might say
/// "white_rice", a Roboflow set "Nasi". Mapping every raw label to one canonical
/// identifier is what lets detections from different models join against the
/// same nutrition row - and it is the join key into the nutrition data layer.
///
/// Mapping is explicit rather than fuzzy on purpose: silently merging
/// "coconut rice" into "rice" would understate the fat of nasi lemak
/// considerably.
struct FoodOntology: Sendable {

    struct Entry: Codable, Equatable, Sendable {
        /// Stable canonical identifier, e.g. "my.rice.coconut".
        let canonicalID: String
        let displayName: String
        /// Raw dataset labels that map to this entry, lowercased.
        let aliases: [String]
        /// Which dataset(s) the aliases came from, for traceability.
        var sources: [String]?
        /// True for foods specific to Malaysian cuisine, used to decide whether
        /// MyFCD or the generic table is the better reference.
        var isMalaysian: Bool?
    }

    private let entries: [Entry]
    /// alias -> entry, built once at load.
    private let aliasIndex: [String: Entry]
    private let canonicalIndex: [String: Entry]

    static let shared = FoodOntology.loadBundled()

    init(entries: [Entry]) {
        self.entries = entries
        var aliases: [String: Entry] = [:]
        var canonical: [String: Entry] = [:]
        for entry in entries {
            canonical[entry.canonicalID] = entry
            // The display name and canonical id are implicit aliases.
            aliases[entry.displayName.lowercased()] = entry
            for alias in entry.aliases {
                aliases[alias.lowercased()] = entry
            }
        }
        self.aliasIndex = aliases
        self.canonicalIndex = canonical
    }

    static func loadBundled(bundle: Bundle = .main) -> FoodOntology {
        guard let url = bundle.url(forResource: "ontology", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return FoodOntology(entries: [])
        }
        return load(data: data)
    }

    static func load(data: Data) -> FoodOntology {
        struct File: Codable { let version: Int; let entries: [Entry] }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return FoodOntology(entries: file.entries)
        } catch {
            // A malformed ontology must not take the app down: recognition
            // simply falls back to raw labels (spec section 34).
            return FoodOntology(entries: [])
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var allEntries: [Entry] { entries }

    /// Resolves a raw model label to a canonical entry.
    func resolve(rawLabel: String) -> Entry? {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models trained by ml/ emit canonical IDs as their class labels.
        if let canonical = canonicalIndex[trimmed] { return canonical }
        let key = trimmed.lowercased()
        if let direct = aliasIndex[key] { return direct }
        // Try a normalised form so "fried_egg" matches an alias of "fried egg".
        let normalised = key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return aliasIndex[normalised]
    }

    func entry(canonicalID: String) -> Entry? { canonicalIndex[canonicalID] }

    /// Substring search over display names, used by manual food search.
    func search(_ query: String, limit: Int = 20) -> [Entry] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return entries
            .filter { entry in
                entry.displayName.lowercased().contains(needle)
                    || entry.aliases.contains { $0.contains(needle) }
            }
            .sorted { lhs, rhs in
                // Prefix matches first, then alphabetical.
                let lhsPrefix = lhs.displayName.lowercased().hasPrefix(needle)
                let rhsPrefix = rhs.displayName.lowercased().hasPrefix(needle)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs.displayName < rhs.displayName
            }
            .prefix(limit)
            .map { $0 }
    }
}
