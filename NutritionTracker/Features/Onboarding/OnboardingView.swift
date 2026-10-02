import SwiftUI
import SwiftData

/// Multi-step onboarding (spec section 5).
///
/// Deliberately paged rather than one long form: each step asks for one group of
/// related facts, and the last step shows the calculated ranges for review and
/// editing before anything is saved.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context

    @State private var step: Step = .welcome
    @State private var input = OnboardingInput()
    @State private var editableRanges = NutritionTargetRanges.zero
    @State private var hasPreparedRanges = false

    enum Step: Int, CaseIterable, Comparable {
        case welcome, basics, body, goal, activity, training, review

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .basics: "About you"
            case .body: "Body"
            case .goal: "Your goal"
            case .activity: "Activity"
            case .training: "Training"
            case .review: "Your daily ranges"
            }
        }

        /// Progress excludes the welcome screen, which asks for nothing.
        var progressIndex: Int { max(0, rawValue - 1) }
        static var progressTotal: Int { Step.allCases.count - 1 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step != .welcome {
                    ProgressView(value: Double(step.progressIndex),
                                 total: Double(Step.progressTotal))
                        .padding(.horizontal, AppTheme.cardPadding)
                        .padding(.top, 8)
                        .accessibilityLabel("Step \(step.progressIndex + 1) of \(Step.progressTotal)")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                        stepContent
                    }
                    .appPageContent()
                }

                footer
            }
            .appPageSurface()
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                Text("Track what you eat, in ranges.")
                    .font(.title2.bold())
                Text("A few questions let the app work out a sensible daily "
                     + "calorie and macro range for you. Everything stays on "
                     + "this iPhone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("These are estimates to aim at, not medical advice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appCard()

        case .basics:
            VStack(alignment: .leading, spacing: 16) {
                DatePicker("Date of birth",
                           selection: $input.dateOfBirth,
                           in: input.dateOfBirthRange,
                           displayedComponents: .date)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sex used for the BMR calculation")
                        .font(.subheadline)
                    Picker("Sex", selection: $input.sex) {
                        ForEach(BiologicalSex.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("The Mifflin-St Jeor formula uses a different constant "
                         + "for each. It only affects the estimate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .appCard()

        case .body:
            VStack(alignment: .leading, spacing: 16) {
                Text("Metric units").font(.caption).foregroundStyle(.secondary)

                let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    NumericEntryField(title: "Height", value: $input.heightCm, unitLabel: "cm")
                    NumericEntryField(title: "Current weight", value: $input.weightKg,
                                      unitLabel: "kg")
                }

                Divider()

                Toggle("I have a target weight", isOn: $input.hasTargetWeight)
                if input.hasTargetWeight {
                    NumericEntryField(title: "Target weight",
                                      value: $input.targetWeightKg, unitLabel: "kg")
                }

                Divider()

                Toggle("I know my body-fat percentage", isOn: $input.hasBodyFat)
                if input.hasBodyFat {
                    NumericEntryField(title: "Body fat", value: $input.bodyFatPercent,
                                      unitLabel: "%")
                    Text("Stored for context. It does not change the calculation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .appCard()

        case .goal:
            VStack(spacing: 10) {
                ForEach(FitnessGoal.allCases) { goal in
                    SelectionRow(title: goal.displayName,
                                 detail: goal.detail,
                                 isSelected: input.goal == goal) {
                        input.goal = goal
                    }
                }
            }

        case .activity:
            VStack(spacing: 10) {
                ForEach(ActivityLevel.allCases) { level in
                    SelectionRow(title: level.displayName,
                                 detail: level.detail,
                                 isSelected: input.activity == level) {
                        input.activity = level
                    }
                }
                Text("Pick the level that already includes your training. "
                     + "Exercise is not added again on top.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

        case .training:
            VStack(alignment: .leading, spacing: 16) {
                Stepper("Strength sessions: \(input.strengthSessions)/week",
                        value: $input.strengthSessions, in: 0...14)
                Divider()
                Stepper("Cardio sessions: \(input.cardioSessions)/week",
                        value: $input.cardioSessions, in: 0...14)
                Text("Kept as part of your profile. Your activity level above "
                     + "already accounts for the calories, so these are not "
                     + "counted twice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appCard()

        case .review:
            reviewStep
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Targets are ranges, not single numbers.")
                    .font(.subheadline.weight(.semibold))
                Text("The formulas behind these figures carry a real margin of "
                     + "error, so aiming at a band is more honest than a single "
                     + "number. Edit any bound you disagree with.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appCard()

            ForEach(Nutrient.allCases) { nutrient in
                RangeEditorRow(nutrient: nutrient,
                               range: Binding(
                                get: { editableRanges[nutrient] },
                                set: { editableRanges[nutrient] = $0 }))
            }

            if let breakdown {
                VStack(alignment: .leading, spacing: 6) {
                    AppSectionHeading(title: "How this was worked out")
                    detailRow("Age", "\(breakdown.age)")
                    detailRow("BMR (Mifflin-St Jeor)",
                              "\(AppFormatters.amount(breakdown.bmr)) kcal")
                    detailRow("Maintenance (with activity)",
                              "\(AppFormatters.amount(breakdown.tdee)) kcal")
                    detailRow("Goal adjustment",
                              "\u{00D7}\(String(format: "%.2f", breakdown.goalMultiplier))")
                    detailRow("Calorie midpoint",
                              "\(AppFormatters.amount(breakdown.caloriePointEstimate)) kcal")
                }
                .appCard()
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.footnote.weight(.medium)).monospacedDigit()
        }
    }

    private var breakdown: NutritionTargetCalculator.Breakdown? {
        guard input.isBodyValid else { return nil }
        return input.calculate()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") { goBack() }
                        .buttonStyle(.bordered)
                }

                Button(step == .review ? "Save and start" : "Continue") {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(validationMessage != nil)
            }
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var validationMessage: String? {
        switch step {
        case .body:
            if input.heightCm <= 0 || input.weightKg <= 0 {
                return "Enter your height and weight to continue."
            }
            if input.hasTargetWeight && input.targetWeightKg <= 0 {
                return "Enter a target weight, or turn that off."
            }
            if input.hasBodyFat && (input.bodyFatPercent <= 0 || input.bodyFatPercent >= 70) {
                return "Enter a body-fat percentage between 1 and 70."
            }
            return nil
        case .review:
            return editableRanges.calories.max > 0 ? nil : "Calorie range cannot be zero."
        default:
            return nil
        }
    }

    private func advance() {
        if step == .review {
            save()
            return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.snappy) { step = next }

        // Calculate once on arrival at review, then leave the user's edits alone.
        if next == .review, !hasPreparedRanges {
            editableRanges = input.calculate().ranges
            hasPreparedRanges = true
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.snappy) { step = previous }
    }

    private func save() {
        let profile = input.makeProfile()
        context.insert(profile)
        profile.markTargetsCalculated()

        let target = NutritionTarget(ranges: editableRanges)
        context.insert(target)

        let settings = context.loadAppSettings()
        settings.hasCompletedOnboarding = true

        do {
            try context.save()
            Haptics.success()
        } catch {
            // Saving the profile is the one thing onboarding must achieve; if it
            // fails there is nothing useful to continue into.
            Haptics.error()
        }
    }
}

// MARK: - Input holder

/// Mutable onboarding answers, kept out of the view so the calculation is
/// testable without SwiftUI.
struct OnboardingInput {
    var dateOfBirth: Date = {
        Calendar.autoupdatingCurrent.date(byAdding: .year, value: -25, to: .now) ?? .now
    }()
    var sex: BiologicalSex = .female
    var heightCm: Double = 0
    var weightKg: Double = 0
    var hasTargetWeight = false
    var targetWeightKg: Double = 0
    var hasBodyFat = false
    var bodyFatPercent: Double = 0
    var goal: FitnessGoal = .maintain
    var activity: ActivityLevel = .moderate
    var strengthSessions: Int = 0
    var cardioSessions: Int = 0

    var dateOfBirthRange: ClosedRange<Date> {
        let calendar = Calendar.autoupdatingCurrent
        let oldest = calendar.date(byAdding: .year, value: -100, to: .now) ?? .distantPast
        let youngest = calendar.date(byAdding: .year, value: -13, to: .now) ?? .now
        return oldest...youngest
    }

    var isBodyValid: Bool { heightCm > 0 && weightKg > 0 }

    func calculate(now: Date = .now,
                   calendar: Calendar = .autoupdatingCurrent) -> NutritionTargetCalculator.Breakdown {
        let years = calendar.dateComponents([.year], from: dateOfBirth, to: now).year ?? 25
        return NutritionTargetCalculator.calculate(weightKg: weightKg,
                                                   heightCm: heightCm,
                                                   age: max(1, years),
                                                   sex: sex,
                                                   goal: goal,
                                                   activity: activity)
    }

    func makeProfile() -> UserProfile {
        UserProfile(dateOfBirth: dateOfBirth,
                    sex: sex,
                    heightCm: heightCm,
                    weightKg: weightKg,
                    targetWeightKg: hasTargetWeight ? targetWeightKg : nil,
                    goal: goal,
                    activity: activity,
                    strengthSessionsPerWeek: strengthSessions,
                    cardioSessionsPerWeek: cardioSessions,
                    bodyFatPercent: hasBodyFat ? bodyFatPercent : nil)
    }
}

// MARK: - Shared rows

struct SelectionRow: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
            .appCard()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Editor for one nutrient band. Editing a bound marks it as manually modified,
/// so a later recalculation preserves it (spec section 6).
struct RangeEditorRow: View {
    let nutrient: Nutrient
    @Binding var range: NutrientRange

    @State private var minValue: Double = 0
    @State private var maxValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(AppTheme.color(for: nutrient))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(nutrient.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if range.isManuallyModified {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                NumericEntryField(title: "Minimum", value: $minValue,
                                  unitLabel: nutrient.unitLabel)
                NumericEntryField(title: "Maximum", value: $maxValue,
                                  unitLabel: nutrient.unitLabel)
            }

            if minValue > maxValue, maxValue > 0 {
                Text("Minimum is above maximum; they will be swapped.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .appCard()
        .onAppear {
            minValue = range.min
            maxValue = range.max
        }
        .onChange(of: minValue) { _, newValue in
            guard newValue != range.min else { return }
            range = range.withManualMin(newValue)
        }
        .onChange(of: maxValue) { _, newValue in
            guard newValue != range.max else { return }
            range = range.withManualMax(newValue)
        }
    }
}
