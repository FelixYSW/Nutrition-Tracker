import Foundation

/// Works out where a "what can I eat here" question is about.
///
/// The model is told to put a named mall or area in `place`, but it sometimes
/// leaves it out (or tucks it into `preferences`). The app then used the GPS
/// location and labelled the search "near you", which looked like the place
/// the user named had been ignored. So the user's own message is checked too:
/// an area they named always wins over their current location.
enum AssistantPlaceResolver {

    /// Where the search is for: what the model sent, else a place named in the
    /// user's message, else nil (meaning "around where they are").
    static func place(arguments: [String: JSONValue], userText: String?) -> String? {
        if let named = AssistantViewModel.namedPlace(in: arguments) { return named }
        guard let userText else { return nil }
        return placeNamed(in: userText)
    }

    /// Words that follow "in" / "at" / "near" but are not a place.
    private static let notPlaces: Set<String> = [
        "me", "my", "here", "there", "this", "that", "these", "those", "a", "an", "some",
        "any", "general", "order", "moderation", "total", "addition", "case", "mind",
        "morning", "evening", "afternoon", "night", "tonight", "today",
        "lunch", "dinner", "breakfast", "supper", "time", "hurry", "rush", "bed", "home",
        "work", "office", "town", "area", "city", "the", "i", "it", "which", "what",
        "relation", "terms", "line", "range", "fact", "short", "future", "past"
    ]

    /// Words that end the place: the rest of the sentence is about the food.
    private static let stopWords: Set<String> = [
        "under", "below", "over", "above", "for", "with", "without", "that", "which",
        "who", "but", "so", "please", "pls", "cheap", "cheaper", "high", "low", "halal",
        "vegetarian", "vegan", "budget", "within", "and", "or", "i", "we", "can", "could",
        "should", "to", "because", "since", "if", "when", "now", "today", "tonight",
        "tomorrow", "right", "later", "then", "good", "best", "healthy", "healthier",
        "light", "lighter", "something", "anything", "got", "have", "has", "is", "are",
        "do", "does", "will", "would", "like", "maybe", "also"
    ]

    private static let prepositions: Set<String> = [
        "at", "in", "around", "near", "inside", "within", "nearby", "@"
    ]

    /// The first "in / at / around / near <place>" phrase of `text`, or nil.
    /// Reads words until a punctuation mark, a stop word or a price, and takes
    /// at most six, so "what to eat in Sunway Pyramid under RM20" gives
    /// "Sunway Pyramid".
    static func placeNamed(in text: String) -> String? {
        // Punctuation and symbols trimmed off a word, keeping the ones that
        // belong in names: "Pavilion KL", "Mid Valley & Gardens", "Jaya One".
        var trimmed = CharacterSet.punctuationCharacters.union(.symbols)
        trimmed.subtract(CharacterSet(charactersIn: "&'’.-"))
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated() {
            let word = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard prepositions.contains(word) || token == "@" else { continue }

            var parts: [String] = []
            for next in tokens[(index + 1)...] {
                let bare = next.trimmingCharacters(in: trimmed)
                let lower = bare.lowercased()
                if bare.isEmpty { break }
                if parts.isEmpty, lower == "the" { continue }
                if parts.isEmpty, notPlaces.contains(lower) { break }
                // A time or amount ("7pm", "500g") is not where.
                if parts.isEmpty, lower.first?.isNumber == true, lower.contains(where: \.isLetter) { break }
                if !parts.isEmpty, stopWords.contains(lower) || prepositions.contains(lower) { break }
                // A price or amount ends the place: "RM15", "$10", "500kcal".
                if !parts.isEmpty, lower.hasPrefix("rm") || lower.hasPrefix("$")
                    || (lower.first?.isNumber == true && lower.contains(where: \.isLetter)) { break }
                parts.append(bare)
                if parts.count == 6 { break }
                if let last = next.last, ",.?!;:".contains(last) { break }
            }
            let candidate = parts.joined(separator: " ")
            // The first phrase that is a place: later ones are usually detail
            // ("... in Pavilion near the lift").
            if !candidate.isEmpty { return candidate }
        }
        return nil
    }
}
