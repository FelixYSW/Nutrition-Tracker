import SwiftUI
import SwiftData
import UIKit

struct AddMealView: View {
    @Environment(\.modelContext) private var context
    @Environment(DraftStore.self) private var store
    @Query private var entries: [FoodEntry]
    @Query private var barcodeCache: [BarcodeProductCache]
    @AppStorage("retainImages") private var retainImages = false
    @State private var error: String?
    @State private var keyboardVisible = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FOOD JOURNAL").font(.caption.bold()).tracking(1.4).foregroundStyle(AppTheme.accent)
                        Text("What did you eat?").font(.largeTitle.bold())
                        Text("Add a food or build a dish from ingredients.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.bottom, 4)

                    if store.drafts.contains(where: { $0.source == .photoAI }) {
                        Label("Nutrition and portions are estimates. Review before saving.", systemImage: "info.circle.fill")
                            .font(.subheadline).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).appCard()
                    }

                    if store.drafts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "plus.circle.dashed").font(.system(size: 42)).foregroundStyle(AppTheme.accent)
                            Text("Start with a food").font(.headline)
                            Text("You can add more foods before saving.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28).appCard()
                    }

                    ForEach($store.drafts) { $draft in
                        FoodDraftCard(draft: $draft) { store.drafts.removeAll { $0.id == draft.id } }
                    }

                    Button { store.drafts.append(FoodDraft()) } label: {
                        Label("Add another food", systemImage: "plus.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Add Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { AppKeyboard.dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !store.drafts.isEmpty && !keyboardVisible {
                    VStack(spacing: 10) {
                        NutritionSummaryView(nutrition: store.drafts.reduce(.zero) { $0 + $1.total })
                        Button(store.drafts.allSatisfy { Calendar.autoupdatingCurrent.isDateInToday($0.consumedAt) }
                               ? "Add to Today" : "Save Food") { save() }
                            .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 50)
                            .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                            .disabled(!store.drafts.allSatisfy(\.isValid))
                    }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                        .background(.bar)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "Unknown error") }
        }
    }

    private func save() {
        guard !store.drafts.isEmpty, store.drafts.allSatisfy(\.isValid) else { return }
        if let editingID = store.editingID, let old = entries.first(where: { $0.id == editingID }) {
            context.delete(old)
        }
        var retainedPath: String?
        if retainImages, let data = store.pendingImage { retainedPath = try? ImageStore.save(data) }
        for index in store.drafts.indices where store.drafts[index].source == .photoAI {
            store.drafts[index].photoPath = retainedPath
        }
        for draft in store.drafts { context.insert(draft.model()) }
        for draft in store.drafts where draft.source == .barcode {
            if let code = draft.barcode, !barcodeCache.contains(where: { $0.barcode == code }) {
                context.insert(BarcodeProductCache(barcode: code, name: draft.name, servingSize: draft.servingSize,
                                                   unit: draft.unit, nutrition: draft.nutrition))
            }
        }
        if let original = store.aiOriginal,
           UserDefaults.standard.bool(forKey: "retainCorrections"),
           let corrected = try? JSONEncoder().encode(store.drafts) {
            context.insert(CorrectionRecord(originalJSON: original, correctedJSON: corrected, photoPath: retainedPath))
        }
        do {
            try context.save()
            store.drafts = []; store.aiOriginal = nil; store.pendingImage = nil; store.editingID = nil
            store.selectedTab = 0
        } catch { self.error = error.localizedDescription }
    }
}

private struct UnitMenu: View {
    @Binding var unit: ServingUnit
    var body: some View {
        Menu {
            ForEach(ServingUnit.allCases) { option in
                Button(option.rawValue.capitalized) { unit = option }
            }
        } label: {
            HStack(spacing: 5) {
                Text(unit.rawValue.capitalized)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }.font(.subheadline.bold()).foregroundStyle(AppTheme.accent)
                .frame(minHeight: 44)
        }
    }
}

struct FoodDraftCard: View {
    @Binding var draft: FoodDraft
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: draft.ingredients.isEmpty ? "fork.knife" : "square.stack.3d.up.fill")
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                TextField("Food name", text: $draft.name)
                    .font(.title3.bold()).textInputAutocapitalization(.words)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .accessibilityLabel("Remove food")
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("DATE & TIME").font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                DatePicker("Consumed at", selection: $draft.consumedAt,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("QUANTITY").font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                HStack {
                    UnitMenu(unit: $draft.unit)
                    Spacer(minLength: 8)
                    QuantityStepper(value: $draft.quantity, unit: draft.unit)
                }
                HStack {
                    Text("Serving size").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Size", value: $draft.servingSize, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .font(.subheadline.bold()).frame(width: 94).padding(.horizontal, 12)
                        .frame(height: 40).background(AppTheme.field, in: RoundedRectangle(cornerRadius: 11))
                }
            }
            if draft.quantity == 0 { Button("Remove zero-quantity food", role: .destructive, action: remove) }

            Divider()
            if draft.ingredients.isEmpty {
                DisclosureGroup("Nutrition per serving") { NutritionEditor(nutrition: $draft.nutrition) }
                    .font(.subheadline.bold()).tint(AppTheme.accent)
            } else {
                AppSectionHeading(title: "Ingredients", trailing: "\(draft.ingredients.count)")
                ForEach($draft.ingredients) { $ingredient in
                    IngredientCard(ingredient: $ingredient) { draft.ingredients.removeAll { $0.id == ingredient.id } }
                }
            }
            Button { draft.ingredients.append(IngredientDraft()) } label: {
                Label("Add ingredient", systemImage: "plus.circle.fill")
                    .font(.subheadline.bold()).foregroundStyle(AppTheme.accent)
            }
            Divider()
            HStack {
                Text("Food total").font(.subheadline.bold())
                Spacer()
                Text("\(Int(draft.total.calories)) kcal").font(.headline).monospacedDigit()
            }
        }.appCard()
    }
}

struct IngredientCard: View {
    @Binding var ingredient: IngredientDraft
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Ingredient name", text: $ingredient.name)
                    .font(.subheadline.bold()).textInputAutocapitalization(.words)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .accessibilityLabel("Remove ingredient")
            }
            if let confidence = ingredient.confidence {
                Text("Detection confidence: \(Int(confidence * 100))%\(confidence < 0.6 ? " - check this item" : "")")
                    .font(.caption).foregroundStyle(confidence < 0.6 ? Color.orange : Color.secondary)
            }
            HStack {
                UnitMenu(unit: $ingredient.unit)
                Spacer(minLength: 8)
                QuantityStepper(value: $ingredient.quantity, unit: ingredient.unit)
            }
            if ingredient.quantity == 0 { Button("Remove zero-quantity ingredient", role: .destructive, action: remove) }
            HStack {
                Text("Serving size").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                TextField("Size", value: $ingredient.servingSize, format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.subheadline.bold()).frame(width: 94).padding(.horizontal, 12)
                    .frame(height: 40).background(AppTheme.card, in: RoundedRectangle(cornerRadius: 11))
            }
            DisclosureGroup("Nutrition per serving") { NutritionEditor(nutrition: $ingredient.nutrition) }
                .font(.subheadline.bold()).tint(AppTheme.accent)
            HStack {
                Text("Ingredient total").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(ingredient.total.calories)) kcal").font(.subheadline.bold()).monospacedDigit()
            }
        }.padding(14).background(AppTheme.field, in: RoundedRectangle(cornerRadius: 16))
    }
}
