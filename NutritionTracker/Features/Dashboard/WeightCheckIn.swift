import SwiftUI
import SwiftData

/// Asks for a fresh weight every couple of weeks, because weight is the input
/// that moves the daily ranges most. Shown on Today when `isCheckInDue`.
struct WeightCheckInCard: View {
    let profile: UserProfile
    let onUpdate: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "scalemass")
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                Text("Time to update your weight")
                    .font(.system(.headline, design: .rounded))
            }
            Text("Last updated \(Self.ago(profile.daysSinceUpdate())). Your daily calories "
                 + "and macros are recalculated from it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Update weight", action: onUpdate)
                    .buttonStyle(.appPrimary)
                Button("Later", action: onLater)
                    .buttonStyle(.appSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private static func ago(_ days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "yesterday"
        default: "\(days) days ago"
        }
    }
}

/// Weight and activity on their own, so a check-in takes a few seconds instead
/// of opening the whole profile. Saving always recalculates the ranges; any
/// bound edited by hand is kept, as everywhere else.
struct WeightCheckInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let profile: UserProfile
    @State private var weightKg: Double = 0
    @State private var activity: ActivityLevel = .sedentary

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        SliderEntryRow(title: "Weight", value: $weightKg,
                                       range: 30...200, step: 0.5, unitLabel: "kg",
                                       fractionDigits: 1)
                    } footer: {
                        Text("Weigh yourself in the morning, after the toilet and before eating, "
                             + "as often as you set in Settings.")
                    }
                    Section {
                        Picker("Activity", selection: $activity) {
                            ForEach(ActivityLevel.allCases) { Text($0.displayName).tag($0) }
                        }
                    } footer: {
                        Text("Change this if your routine has changed. Height, birthday and sex "
                             + "rarely need updating; use Profile for those.")
                    }
                }
                .listRowBackground(AppTheme.cardBackground)
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Update weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let before = NutritionTargetCalculator.calculate(profile: profile).tdee
                        profile.weightKg = weightKg
                        profile.activity = activity
                        TargetUpdater.update(for: profile, in: context, previousMaintenance: before)
                        Haptics.success()
                        dismiss()
                    }
                }
            }
            .onAppear {
                weightKg = profile.weightKg
                activity = profile.activity
            }
        }
    }
}
