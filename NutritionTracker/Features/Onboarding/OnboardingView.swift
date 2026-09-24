import SwiftUI
import SwiftData
import UIKit

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
    @State private var keyboardVisible = false

    private var profile: UserProfile {
        UserProfile(dateOfBirth: dob, sex: sex, heightCm: height, weightKg: weight,
                    targetWeightKg: targetWeight, goal: goal, activity: activity,
                    strengthSessions: strength, cardioSessions: cardio, bodyFatPercent: bodyFat)
    }
    private var heading: String {
        switch step { case 0: "Let’s meet"; case 1: "Your routine"; default: "Your daily goals" }
    }
    private var subtitle: String {
        switch step {
        case 0: "A few details help set your starting targets."
        case 1: "Choose the goal and activity level that fit you."
        default: "Review these estimates and change any value."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("NUTRITION TRACKER").font(.caption.bold()).tracking(1.4).foregroundStyle(AppTheme.accent)
                        Text(heading).font(.largeTitle.bold())
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(0..<3) { index in
                                Capsule().fill(index <= step ? AppTheme.accent : AppTheme.divider)
                                    .frame(height: 5)
                            }
                        }.padding(.top, 8)
                        Text("Step \(step + 1) of 3").font(.caption).foregroundStyle(.secondary)
                    }

                    if step == 0 { personalDetails }
                    else if step == 1 { routineDetails }
                    else { targetDetails }
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { AppKeyboard.dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if !keyboardVisible {
                    VStack(spacing: 8) {
                        Button(step == 2 ? "Save my targets" : "Continue") { advance() }
                            .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 50)
                            .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                            .disabled(step == 0 && (height <= 0 || weight <= 0))
                        if step > 0 { Button("Back") { step -= 1 }.font(.subheadline.bold()) }
                    }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8).background(.bar)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        }.tint(AppTheme.accent)
    }

    private var personalDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Personal details", systemImage: "person.crop.circle").font(.headline).foregroundStyle(AppTheme.accent)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Date of birth").font(.subheadline).foregroundStyle(.secondary)
                DatePicker("Date of birth", selection: $dob, in: ...Date.now, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact)
            }
            Picker("Sex used for BMR", selection: $sex) {
                ForEach(BiologicalSex.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }.tint(AppTheme.accent)
            numberRow("Height", unit: "cm", value: $height)
            numberRow("Current weight", unit: "kg", value: $weight)
            HStack {
                Text("Target weight").font(.subheadline)
                Spacer()
                OptionalNumberField(value: $targetWeight).frame(width: 90)
                Text("kg").font(.caption).foregroundStyle(.secondary)
            }
        }.appCard()
    }

    private var routineDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Movement & goals", systemImage: "figure.run").font(.headline).foregroundStyle(AppTheme.accent)
            Divider()
            Picker("Fitness goal", selection: $goal) {
                ForEach(FitnessGoal.allCases) { Text($0.title).tag($0) }
            }.tint(AppTheme.accent)
            Picker("Activity level", selection: $activity) {
                ForEach(ActivityLevel.allCases) { Text($0.title).tag($0) }
            }.tint(AppTheme.accent)
            Stepper("Strength days: \(strength) / week", value: $strength, in: 0...14)
            Stepper("Cardio days: \(cardio) / week", value: $cardio, in: 0...14)
            HStack {
                Text("Body fat").font(.subheadline)
                Spacer()
                OptionalNumberField(value: $bodyFat).frame(width: 90)
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
            Text("Training days are stored for context. Activity already includes exercise calories.")
                .font(.caption).foregroundStyle(.secondary)
        }.appCard()
    }

    private var targetDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Recommended targets", systemImage: "scope").font(.headline).foregroundStyle(AppTheme.accent)
            Divider()
            Text("These are starting estimates, not medical advice. You can edit every value.")
                .font(.subheadline).foregroundStyle(.secondary)
            NutritionEditor(nutrition: $target)
        }.appCard()
    }

    private func numberRow(_ title: String, unit: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            TextField(title, value: value, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .font(.subheadline.bold()).frame(width: 90)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }.frame(minHeight: 44)
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
