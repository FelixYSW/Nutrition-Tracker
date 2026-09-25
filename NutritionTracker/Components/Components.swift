import SwiftUI

struct QuantityStepper: View {
    @Binding var value: Double
    var unit: ServingUnit
    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(0, value - unit.step) } label: {
                Image(systemName: "minus").font(.subheadline.bold()).frame(width: 42, height: 42)
            }
                .accessibilityLabel("Decrease quantity")
            Text(value.formatted(.number.precision(.fractionLength(0...2))))
                .font(.subheadline.bold()).monospacedDigit().frame(minWidth: 42)
            Button { value += unit.step } label: {
                Image(systemName: "plus").font(.subheadline.bold()).frame(width: 42, height: 42)
            }
                .accessibilityLabel("Increase quantity")
        }
        .buttonStyle(.plain).foregroundStyle(AppTheme.accent)
        .background(AppTheme.accent.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

struct NutritionSummaryView: View {
    var nutrition: Nutrition
    var body: some View {
        HStack(spacing: 4) {
            metric("kcal", nutrition.calories)
            metric("Protein", nutrition.protein)
            metric("Carbs", nutrition.carbs)
            metric("Fat", nutrition.fat)
        }
    }
    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted(.number.precision(.fractionLength(0))))
                .font(.subheadline.bold()).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct CircularNutritionProgress: View {
    let title: String
    let consumed: Double
    let target: Double
    let color: Color
    var size: CGFloat = 74
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 8)
                Circle().trim(from: 0, to: min(1, max(0, consumed / max(target, 1))))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(consumed.formatted(.number.precision(.fractionLength(0))))
                    .font(.subheadline.bold()).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
            }.frame(width: size, height: size)
            Text(title).font(.caption.bold())
            Text("/ \(Int(target))").font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(Int(consumed)) of \(Int(target))")
    }
}

struct FoodEntryCard: View {
    let entry: FoodEntry
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: entry.source == .barcode ? "barcode" : entry.source == .photoAI ? "camera.fill" : "fork.knife")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.headline).lineLimit(2)
                    Text(entry.consumedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(entry.total.calories))").font(.title3.bold()).monospacedDigit()
                    Text("kcal").font(.caption2).foregroundStyle(.secondary)
                }
                if let onEdit, let onDelete {
                    Menu {
                        Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis").font(.headline)
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Actions for \(entry.name)")
                    }
                }
            }
            NutritionSummaryView(nutrition: entry.total)
            if !entry.ingredients.isEmpty {
                Button { expanded.toggle() } label: {
                    HStack {
                        Text(expanded ? "Hide ingredients" : "\(entry.ingredients.count) ingredients")
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(.subheadline.bold()).foregroundStyle(AppTheme.accent)
                }
                if expanded {
                    ForEach(entry.ingredients, id: \.id) { ingredient in
                        HStack { Text(ingredient.name); Spacer(); Text("\(Int(ingredient.total.calories)) kcal") }
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }.appCard()
    }
}

struct EmptyStateView: View {
    let title: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 46, weight: .light)).foregroundStyle(AppTheme.accent)
            Text(title).font(.headline)
            Text("Your food will appear here once you add it.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 36).appCard()
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
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField(label, value: value, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .font(.subheadline.bold()).monospacedDigit()
                .frame(width: 94).padding(.horizontal, 12).frame(height: 40)
                .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 11))
        }.frame(minHeight: 44)
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
