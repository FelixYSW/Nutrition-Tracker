import SwiftUI

/// What a new, empty chat shows: the app's mark, a greeting for this point
/// in the day, where today stands, and a few suggestions that show what the
/// assistant can do - different at breakfast, lunch, dinner and late night.
struct EmptyChatView: View {
    /// Today's calories so far; nil before any targets exist.
    let caloriesSoFar: Double
    let calorieRange: NutrientRange?
    let hasLoggedToday: Bool
    var now: Date = .now

    /// Sends a question straight away.
    let onAsk: (String) -> Void
    /// Starts a message for the user to finish, e.g. "For lunch I had ".
    let onDraft: (String) -> Void
    /// Starts a menu question and opens the camera or the photo library.
    let onMenuPhoto: (_ fromCamera: Bool) -> Void

    private var moment: Moment { Moment(date: now) }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)

            AppLogoMark(size: 64)

            VStack(spacing: 6) {
                Text(moment.greeting)
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .multilineTextAlignment(.center)
                Text(Self.statusLine(caloriesSoFar: caloriesSoFar, range: calorieRange,
                                     hasLoggedToday: hasLoggedToday))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CenteredFlowLayout(spacing: 8) {
                ForEach(moment.suggestions) { suggestion in
                    chip(for: suggestion)
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 12)

            Text("Sees your ranges and food log. Always asks before changing anything.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, AppTheme.cardPadding + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chips

    @ViewBuilder
    private func chip(for suggestion: Suggestion) -> some View {
        switch suggestion.action {
        case .menuPhoto:
            // Take a photo of the menu there and then, or pick one.
            Menu {
                Button("Take Photo", systemImage: "camera") { onMenuPhoto(true) }
                Button("Choose Photo", systemImage: "photo.on.rectangle") { onMenuPhoto(false) }
            } label: {
                chipLabel(suggestion)
            }
        case .ask(let question):
            Button { onAsk(question) } label: { chipLabel(suggestion) }
                .buttonStyle(.plain)
        case .draft(let start):
            Button { onDraft(start) } label: { chipLabel(suggestion) }
                .buttonStyle(.plain)
        }
    }

    private func chipLabel(_ suggestion: Suggestion) -> some View {
        Label(suggestion.title, systemImage: suggestion.symbol)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: AppTheme.minimumTapTarget)
            .background(AppTheme.cardBackground, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.cardBorder, lineWidth: 1))
            .contentShape(Capsule())
    }

    // MARK: Status

    /// "1,420 kcal so far · 380 kcal to reach your range", or a plain line
    /// when nothing is logged or there are no targets yet.
    static func statusLine(caloriesSoFar: Double, range: NutrientRange?,
                           hasLoggedToday: Bool) -> String {
        guard let range, range.max > 0 else {
            return "Ask me anything about what you eat."
        }
        guard hasLoggedToday else {
            return "Nothing logged yet today. Your range is \(AppFormatters.range(range)) kcal."
        }
        let soFar = "\(AppFormatters.amount(caloriesSoFar)) kcal so far"
        switch range.state(consumed: caloriesSoFar) {
        case .under:
            let gap = AppFormatters.amount(range.min.rounded() - caloriesSoFar.rounded())
            return "\(soFar) \u{00B7} \(gap) kcal to reach your range"
        case .within:
            return "\(soFar) \u{00B7} in range"
        case .over:
            let extra = AppFormatters.amount(caloriesSoFar.rounded() - range.max.rounded())
            return "\(soFar) \u{00B7} \(extra) kcal over"
        }
    }

    // MARK: Moments

    /// The part of the day, which sets the greeting and the suggestions.
    enum Moment: Equatable {
        case breakfast, lunch, afternoon, dinner, lateNight

        init(date: Date, calendar: Calendar = .autoupdatingCurrent) {
            switch calendar.component(.hour, from: date) {
            case 5..<11: self = .breakfast
            case 11..<15: self = .lunch
            case 15..<18: self = .afternoon
            case 18..<22: self = .dinner
            default: self = .lateNight
            }
        }

        var greeting: String {
            switch self {
            case .breakfast: "Good morning"
            case .lunch: "Lunchtime"
            case .afternoon: "Afternoon"
            case .dinner: "Good evening"
            case .lateNight: "Up late?"
            }
        }

        var suggestions: [Suggestion] {
            let menu = Suggestion(title: "What's on the menu?", symbol: "camera",
                                  action: .menuPhoto)
            switch self {
            case .breakfast:
                return [
                    Suggestion(title: "Log my breakfast", symbol: "plus",
                               action: .draft("For breakfast I had ")),
                    Suggestion(title: "Same breakfast as yesterday", symbol: "arrow.clockwise",
                               action: .ask("I had the same breakfast as yesterday.")),
                    menu,
                    Suggestion(title: "How did yesterday go?", symbol: "chart.bar",
                               action: .ask("How did yesterday go against my ranges?"))
                ]
            case .lunch:
                return [
                    Suggestion(title: "Log my lunch", symbol: "plus",
                               action: .draft("For lunch I had ")),
                    menu,
                    Suggestion(title: "Food near me", symbol: "location",
                               action: .ask("What can I get for lunch near me that fits my ranges?")),
                    Suggestion(title: "What fits my day?", symbol: "sparkles",
                               action: .ask("What should I eat for lunch with what I have left today?"))
                ]
            case .afternoon:
                return [
                    Suggestion(title: "Log a snack", symbol: "plus",
                               action: .draft("For a snack I had ")),
                    Suggestion(title: "A high-protein snack", symbol: "dumbbell",
                               action: .ask("Suggest a snack that helps my protein without "
                                            + "going over my calories.")),
                    menu,
                    Suggestion(title: "How's my week?", symbol: "chart.bar",
                               action: .ask("How has this week gone against my ranges?"))
                ]
            case .dinner:
                return [
                    Suggestion(title: "Log my dinner", symbol: "plus",
                               action: .draft("For dinner I had ")),
                    menu,
                    Suggestion(title: "What should I eat?", symbol: "sparkles",
                               action: .ask("What should I eat for dinner with what I have left today?")),
                    Suggestion(title: "Food near me", symbol: "location",
                               action: .ask("What can I get for dinner near me that fits my ranges?"))
                ]
            case .lateNight:
                return [
                    Suggestion(title: "Log a late snack", symbol: "plus",
                               action: .draft("Just now I had ")),
                    Suggestion(title: "How did today go?", symbol: "chart.bar",
                               action: .ask("How did today go against my ranges?")),
                    Suggestion(title: "Plan tomorrow", symbol: "calendar",
                               action: .ask("Help me plan tomorrow's meals to land in my ranges.")),
                    menu
                ]
            }
        }
    }

    struct Suggestion: Identifiable, Equatable {
        enum Action: Equatable {
            case ask(String)
            case draft(String)
            case menuPhoto
        }
        var id: String { title }
        let title: String
        let symbol: String
        let action: Action
    }
}

/// Lays chips out in rows that wrap, each row centred, like suggestion chips
/// in a chat app.
struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(for: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
