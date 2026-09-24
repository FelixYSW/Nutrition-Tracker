import SwiftUI
import SwiftData

struct AddMealView: View {
    @Environment(\.modelContext) private var context
    @Environment(DraftStore.self) private var store
    @Query private var entries: [FoodEntry]
    @Query private var barcodeCache: [BarcodeProductCache]
    @AppStorage("retainImages") private var retainImages = false
    @State private var error: String?
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if store.drafts.contains(where: { $0.source == .photoAI }) {
                        Text("Nutrition and portions are estimates. Review before saving.")
                            .font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach($store.drafts) { $draft in
                        FoodDraftCard(draft: $draft) {
                            store.drafts.removeAll { $0.id == draft.id }
                        }
                    }
                    Button { store.drafts.append(FoodDraft()) } label: { Label("Add food", systemImage: "plus.circle.fill") }
                        .buttonStyle(.bordered)
                    if !store.drafts.isEmpty {
                        NutritionSummaryView(nutrition: store.drafts.reduce(.zero) { $0 + $1.total })
                        Button(store.drafts.allSatisfy { Calendar.autoupdatingCurrent.isDateInToday($0.consumedAt) } ? "ADD TO TODAY" : "SAVE FOOD") { save() }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            .disabled(!store.drafts.allSatisfy(\.isValid))
                    }
                }.padding()
            }.navigationTitle("Add Meal")
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
        if retainImages, let data = store.pendingImage {
            retainedPath = try? ImageStore.save(data)
        }
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

struct FoodDraftCard: View {
    @Binding var draft: FoodDraft
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Food name", text: $draft.name).font(.headline)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .accessibilityLabel("Remove food")
            }
            DatePicker("Consumed", selection: $draft.consumedAt)
            HStack {
                Picker("Unit", selection: $draft.unit) { ForEach(ServingUnit.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                QuantityStepper(value: $draft.quantity, unit: draft.unit)
            }
            if draft.quantity == 0 { Button("Remove zero-quantity food", role: .destructive, action: remove) }
            LabeledContent("Serving size") { TextField("Size", value: $draft.servingSize, format: .number).keyboardType(.decimalPad) }
            if draft.ingredients.isEmpty {
                DisclosureGroup("Nutrition per serving") { NutritionEditor(nutrition: $draft.nutrition) }
            } else {
                ForEach($draft.ingredients) { $ingredient in
                    IngredientCard(ingredient: $ingredient) { draft.ingredients.removeAll { $0.id == ingredient.id } }
                }
            }
            Button { draft.ingredients.append(IngredientDraft()) } label: { Label("Add ingredient", systemImage: "plus") }
            NutritionSummaryView(nutrition: draft.total)
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct IngredientCard: View {
    @Binding var ingredient: IngredientDraft
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Ingredient", text: $ingredient.name)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .accessibilityLabel("Remove ingredient")
            }
            if let confidence = ingredient.confidence {
                Text("Detection confidence: \(Int(confidence * 100))%\(confidence < 0.6 ? " — check this item" : "")")
                    .font(.caption).foregroundStyle(confidence < 0.6 ? .orange : .secondary)
            }
            HStack {
                Picker("Unit", selection: $ingredient.unit) { ForEach(ServingUnit.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                QuantityStepper(value: $ingredient.quantity, unit: ingredient.unit)
            }
            if ingredient.quantity == 0 { Button("Remove zero-quantity ingredient", role: .destructive, action: remove) }
            LabeledContent("Serving size") { TextField("Size", value: $ingredient.servingSize, format: .number).keyboardType(.decimalPad) }
            DisclosureGroup("Nutrition per serving") { NutritionEditor(nutrition: $ingredient.nutrition) }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
