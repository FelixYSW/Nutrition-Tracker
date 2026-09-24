import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @State private var step = 0
    @State private var dob = Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now
    @State private var sex = BiologicalSex.female
    @State private var height = 170.0
    @State private var weight = 70.0
    @State private var targetWeight: Double?
    @State private var goal = FitnessGoal.maintain
    @State private var activity = ActivityLevel.moderate
    @State private var strength = 0
    @State private var cardio = 0
    @State private var bodyFat: Double?
    @State private var target = Nutrition.zero
    @State private var suggested = Nutrition.zero
    private var profile: UserProfile {
        UserProfile(dateOfBirth: dob, sex: sex, heightCm: height, weightKg: weight,
                    targetWeightKg: targetWeight, goal: goal, activity: activity,
                    strengthSessions: strength, cardioSessions: cardio, bodyFatPercent: bodyFat)
    }
    var body: some View {
        NavigationStack {
            Form {
                if step == 0 {
                    Section("About you") {
                        DatePicker("Date of birth", selection: $dob, in: ...Date.now, displayedComponents: .date)
                        Picker("Sex for BMR", selection: $sex) { ForEach(BiologicalSex.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                        LabeledContent("Height (cm)") { TextField("cm", value: $height, format: .number).keyboardType(.decimalPad) }
                        LabeledContent("Weight (kg)") { TextField("kg", value: $weight, format: .number).keyboardType(.decimalPad) }
                        LabeledContent("Target weight (kg), optional") { OptionalNumberField(value: $targetWeight) }
                    }
                } else if step == 1 {
                    Section("Your routine") {
                        Picker("Goal", selection: $goal) { ForEach(FitnessGoal.allCases) { Text($0.title).tag($0) } }
                        Picker("Activity", selection: $activity) { ForEach(ActivityLevel.allCases) { Text($0.title).tag($0) } }
                        Stepper("Strength sessions/week: \(strength)", value: $strength, in: 0...14)
                        Stepper("Cardio sessions/week: \(cardio)", value: $cardio, in: 0...14)
                        LabeledContent("Body fat %, optional") { OptionalNumberField(value: $bodyFat) }
                    }
                } else {
                    Section("Daily targets") {
                        Text("These are starting estimates, not medical advice. You can edit every value.")
                            .font(.footnote).foregroundStyle(.secondary)
                        NutritionEditor(nutrition: $target)
                    }
                }
                Section {
                    Button(step == 2 ? "Save and continue" : "Continue") { advance() }
                        .disabled(step == 0 && (height <= 0 || weight <= 0))
                    if step > 0 { Button("Back") { step -= 1 } }
                }
            }.navigationTitle("Welcome")
        }
    }
    private func advance() {
        if step == 1 { suggested = NutritionTargetCalculator.calculate(profile: profile); target = suggested }
        if step < 2 { step += 1; return }
        guard target.isValid, target.calories > 0 else { return }
        context.insert(profile)
        context.insert(NutritionTarget(target, manuallyModified: target != suggested))
        try? context.save()
    }
}
