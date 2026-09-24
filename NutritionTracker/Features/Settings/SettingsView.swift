import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @Query private var targets: [NutritionTarget]
    @Query private var entries: [FoodEntry]
    @Query private var cache: [BarcodeProductCache]
    @State private var targetDraft = Nutrition.zero
    @State private var apiKey = ""
    @State private var showExport = false
    @State private var showImport = false
    @State private var showDelete = false
    @State private var document = BackupDocument()
    @State private var message: String?
    @AppStorage("retainImages") private var retainImages = false
    @AppStorage("retainCorrections") private var retainCorrections = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    if let p = profiles.first {
                        LabeledContent("Height (cm)") { TextField("Height", value: Binding(get: { p.heightCm }, set: { p.heightCm = $0 }), format: .number).keyboardType(.decimalPad) }
                        LabeledContent("Weight (kg)") { TextField("Weight", value: Binding(get: { p.weightKg }, set: { p.weightKg = $0 }), format: .number).keyboardType(.decimalPad) }
                        Picker("Goal", selection: Binding(get: { p.goal }, set: { p.goalRaw = $0.rawValue })) {
                            ForEach(FitnessGoal.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Activity", selection: Binding(get: { p.activity }, set: { p.activityRaw = $0.rawValue })) {
                            ForEach(ActivityLevel.allCases) { Text($0.title).tag($0) }
                        }
                        Button("Recalculate targets") {
                            targetDraft = NutritionTargetCalculator.calculate(profile: p)
                            message = "Review the new values and tap Save Targets."
                        }
                    }
                }
                Section("Daily Targets") {
                    NutritionEditor(nutrition: $targetDraft)
                    Button("Save Targets") {
                        guard targetDraft.isValid, targetDraft.calories > 0 else { message = "Enter valid targets."; return }
                        targets.first?.update(targetDraft, manual: true)
                        try? context.save()
                    }
                }
                Section("AI") {
                    LabeledContent("Food recognition") { Text(modelStatus("FoodRecognition")).foregroundStyle(.secondary) }
                    LabeledContent("Portion estimation") { Text(modelStatus("FoodPortion")).foregroundStyle(.secondary) }
                    SecureField("Optional remote API key", text: $apiKey)
                    Button("Save API Key") { message = SecretStore.save(apiKey) ? "Key stored in Keychain." : "Could not store key."; apiKey = "" }
                    Button("Delete API Key", role: .destructive) { SecretStore.delete(); message = "Key deleted." }
                    Toggle("Keep corrected AI results locally", isOn: $retainCorrections)
                    Text("Remote analysis requires a provider integration. The key alone does not enable it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Data") {
                    Toggle("Retain analysed images", isOn: $retainImages)
                    Button("Export Backup") { export() }
                    Button("Import Backup") { showImport = true }
                    Button("Delete All Data", role: .destructive) { showDelete = true }
                }
                Section("About") {
                    Text("Nutrition and photo portions are estimates, not medical advice.")
                    Text("FoodSeg103 · Nutrition5k · MyFCD · Open Food Facts · Malaysia Food-11 · MF-150 · Roboflow Malaysian Food Recognition")
                        .font(.footnote)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                }
            }.navigationTitle("Settings")
                .toolbar { Button("Done") { dismiss() } }
                .onAppear { targetDraft = targets.first?.nutrition ?? .zero }
                .fileExporter(isPresented: $showExport, document: document, contentType: .json,
                              defaultFilename: "NutritionTracker-backup") { result in
                    if case .failure(let error) = result { message = error.localizedDescription }
                }
                .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get()
                        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                        defer { url.stopAccessingSecurityScopedResource() }
                        let backup = try BackupService.decode(Data(contentsOf: url))
                        restore(backup)
                    } catch { message = error.localizedDescription }
                }
                .confirmationDialog("Delete all nutrition data?", isPresented: $showDelete) {
                    Button("Delete All Data", role: .destructive) { deleteAll() }
                }
                .alert("Settings", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("OK") { message = nil }
                } message: { Text(message ?? "") }
        }
    }
    private func modelStatus(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc") == nil ? "Unavailable" : "Installed"
    }
    private func export() {
        let backup = NutritionBackup(profile: profiles.first.map(ProfileBackup.init),
                                     target: targets.first.map(TargetBackup.init),
                                     foodEntries: entries.map(FoodBackup.init), barcodeCache: cache.map(BarcodeBackup.init))
        do { document = BackupDocument(data: try BackupService.encode(backup)); showExport = true }
        catch { message = error.localizedDescription }
    }
    private func restore(_ backup: NutritionBackup) {
        // Decode and validate the whole file before mutating SwiftData.
        deleteAll(save: false)
        if let profile = backup.profile { context.insert(profile.model()) }
        if let target = backup.target { context.insert(target.model()) }
        backup.foodEntries.forEach { context.insert($0.model()) }
        backup.barcodeCache.forEach { context.insert($0.model()) }
        do { try context.save(); message = "Backup restored." }
        catch { context.rollback(); message = "Restore failed: \(error.localizedDescription)" }
    }
    private func deleteAll(save: Bool = true) {
        entries.forEach(context.delete); cache.forEach(context.delete)
        targets.forEach(context.delete); profiles.forEach(context.delete)
        if save { try? context.save() }
    }
}
