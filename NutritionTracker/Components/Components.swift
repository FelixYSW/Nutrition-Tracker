import SwiftUI

struct QuantityStepper: View {
    @Binding var value: Double
    var unit: ServingUnit
    var body: some View {
        HStack(spacing: 12) {
            Button { value = max(0, value - unit.step) } label: { Image(systemName: "minus.circle.fill") }
                .accessibilityLabel("Decrease quantity")
            Text(value.formatted(.number.precision(.fractionLength(0...2))))
                .monospacedDigit().frame(minWidth: 36)
            Button { value += unit.step } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel("Increase quantity")
        }
        .font(.title3).buttonStyle(.plain).foregroundStyle(.tint)
        .frame(minHeight: 44)
    }
}

struct NutritionSummaryView: View {
    var nutrition: Nutrition
    var body: some View {
        HStack {
            metric("kcal", nutrition.calories)
            metric("Protein", nutrition.protein)
            metric("Carbs", nutrition.carbs)
            metric("Fat", nutrition.fat)
        }
    }
    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted(.number.precision(.fractionLength(0))))
                .font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct CircularNutritionProgress: View {
    let title: String
    let consumed: Double
    let target: Double
    let color: Color
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 8)
                Circle().trim(from: 0, to: min(1, max(0, consumed / max(target, 1))))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(consumed.formatted(.number.precision(.fractionLength(0))))
                    .font(.subheadline.bold()).monospacedDigit()
            }.frame(width: 72, height: 72)
            Text(title).font(.caption.bold())
            Text("/ \(Int(target))").font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(Int(consumed)) of \(Int(target))")
    }
}

struct FoodEntryCard: View {
    let entry: FoodEntry
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.name).font(.headline)
                    Text(entry.consumedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(entry.total.calories)) kcal").font(.subheadline.bold())
            }
            NutritionSummaryView(nutrition: entry.total)
            if !entry.ingredients.isEmpty {
                Button(expanded ? "Hide ingredients" : "Show ingredients") { expanded.toggle() }
                    .font(.caption)
                if expanded {
                    ForEach(entry.ingredients, id: \.id) { ingredient in
                        HStack { Text(ingredient.name); Spacer(); Text("\(Int(ingredient.total.calories)) kcal") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct EmptyStateView: View {
    let title: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "fork.knife")
    }
}

struct LoadingAnalysisView: View {
    let stage: String
    var body: some View { VStack(spacing: 12) { ProgressView(); Text(stage) }.padding() }
}

struct NutritionEditor: View {
    @Binding var nutrition: Nutrition
    var body: some View {
        Group {
            field("Calories", value: $nutrition.calories)
            field("Protein (g)", value: $nutrition.protein)
            field("Carbs (g)", value: $nutrition.carbs)
            field("Fat (g)", value: $nutrition.fat)
            field("Fibre (g)", value: $nutrition.fibre)
        }
    }
    private func field(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) { TextField(label, value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }
}

struct OptionalNumberField: View {
    @Binding var value: Double?
    var body: some View {
        TextField("Optional", text: Binding(
            get: { value.map { String($0) } ?? "" },
            set: { value = $0.isEmpty ? nil : Double($0) }
        )).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
    }
}
