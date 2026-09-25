import SwiftUI

struct QuantityStepper: View {
    @Binding var value: Double
    var unit: ServingUnit
    @State private var quantityText: String
    @FocusState private var quantityFocused: Bool

    init(value: Binding<Double>, unit: ServingUnit) {
        _value = value
        self.unit = unit
        _quantityText = State(initialValue: Self.display(value.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { adjust(by: -unit.step) } label: {
                Image(systemName: "minus").font(.subheadline.bold()).frame(width: 42, height: 42)
            }
                .accessibilityLabel("Decrease quantity")
            TextField("Quantity", text: $quantityText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.subheadline.bold()).monospacedDigit()
                .focused($quantityFocused)
                .frame(width: 68, height: 38)
                .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(AppTheme.accent.opacity(0.35), lineWidth: 1))
                .accessibilityLabel("Quantity")
            Button { adjust(by: unit.step) } label: {
                Image(systemName: "plus").font(.subheadline.bold()).frame(width: 42, height: 42)
            }
                .accessibilityLabel("Increase quantity")
        }
        .buttonStyle(.plain).foregroundStyle(AppTheme.accent)
        .background(AppTheme.accent.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .contain)
        .onChange(of: quantityText) { _, newText in
            let parsed = Double(newText.replacingOccurrences(of: ",", with: "."))
            value = parsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        }
        .onChange(of: value) { _, newValue in
            if !quantityFocused { quantityText = Self.display(newValue) }
        }
        .onChange(of: quantityFocused) { _, focused in
            if !focused { quantityText = Self.display(value) }
        }
    }

    private func adjust(by change: Double) {
        value = max(0, value + change)
        quantityText = Self.display(value)
    }

    private static func display(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
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
            field("Calories", unit: "kcal", value: $nutrition.calories)
            field("Protein", unit: "g", value: $nutrition.protein)
            field("Carbs", unit: "g", value: $nutrition.carbs)
            field("Fat", unit: "g", value: $nutrition.fat)
            field("Fibre", unit: "g", value: $nutrition.fibre)
        }
    }
    private func field(_ label: String, unit: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            NumericEntryField(value: value, unit: unit, hint: "Enter \(label.lowercased())")
        }.frame(minHeight: 44)
    }
}

struct NumericEntryField: View {
    @Binding var value: Double
    let unit: String
    let hint: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(hint).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 4) {
                TextField("0", value: $value, format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.subheadline.bold()).monospacedDigit()
                    .accessibilityLabel(hint)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 94)
        .padding(.vertical, 5)
        .appInputBox()
    }
}

struct OptionalNumberField: View {
    @Binding var value: Double?
    var hint = "Optional"
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(hint).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            TextField("Optional", text: Binding(
                get: { value.map { String($0) } ?? "" },
                set: { value = $0.isEmpty ? nil : Double($0) }
            ))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            .font(.subheadline.bold())
        }.padding(.vertical, 5).appInputBox()
    }
}
