import Foundation

enum NutritionTargetCalculator {
    // Mifflin-St Jeor; activity already includes exercise, so session counts are not added again.
    static func calculate(profile: UserProfile, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Nutrition {
        let years = max(1, calendar.dateComponents([.year], from: profile.dateOfBirth, to: now).year ?? 18)
        let sexConstant = profile.sex == .male ? 5.0 : -161.0
        let bmr = 10 * profile.weightKg + 6.25 * profile.heightCm - 5 * Double(years) + sexConstant
        let adjustment: Double = switch profile.goal {
        case .loseWeight: 0.80
        case .recomposition: 0.92
        case .maintain: 1.0
        case .buildMuscle: 1.10
        }
        let calories = max(1200, (bmr * profile.activity.multiplier * adjustment).rounded())
        let proteinFactor: Double = switch profile.goal {
        case .loseWeight, .recomposition: 2.0
        case .maintain: 1.6
        case .buildMuscle: 1.8
        }
        let protein = (profile.weightKg * proteinFactor).rounded()
        let fat = max(profile.weightKg * 0.6, calories * 0.25 / 9).rounded()
        let carbs = max(0, ((calories - protein * 4 - fat * 9) / 4).rounded())
        let fibre = (calories / 1000 * 14).rounded()
        return Nutrition(calories: calories, protein: protein, carbs: carbs, fat: fat, fibre: fibre)
    }
}
