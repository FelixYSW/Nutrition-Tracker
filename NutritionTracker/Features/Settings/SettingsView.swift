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

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(AppTheme.accent)
            Divider()
            content
        }.frame(maxWidth: .infinity, alignment: .leading).appCard()
    }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PREFERENCES").font(.caption.bold()).tracking(1.4).foregroundStyle(AppTheme.accent)
                        Text("Make it yours").font(.largeTitle.bold())
                    }.padding(.bottom, 4)

                    SettingsSection("Profile", icon: "person.crop.circle") {
                        if let profile = profiles.first {
                            numberRow("Height", unit: "cm", value: Binding(get: { profile.heightCm }, set: { profile.heightCm = $0 }))
                            numberRow("Weight", unit: "kg", value: Binding(get: { profile.weightKg }, set: { profile.weightKg = $0 }))
                            Picker("Goal", selection: Binding(get: { profile.goal }, set: { profile.goalRaw = $0.rawValue })) {
                                ForEach(FitnessGoal.allCases) { Text($0.title).tag($0) }
                            }.tint(AppTheme.accent)
                            Picker("Activity", selection: Binding(get: { profile.activity }, set: { profile.activityRaw = $0.rawValue })) {
                                ForEach(ActivityLevel.allCases) { Text($0.title).tag($0) }
                            }.tint(AppTheme.accent)
                            Button("Recalculate targets") {
                                targetDraft = NutritionTargetCalculator.calculate(profile: profile)
                                message = "Review the new values and tap Save Targets."
                            }.font(.subheadline.bold())
                        }
                    }

                    SettingsSection("Daily Targets", icon: "scope") {
                        NutritionEditor(nutrition: $targetDraft)
                        Button("Save Targets") {
                            guard targetDraft.isValid, targetDraft.calories > 0 else { message = "Enter valid targets."; return }
                            targets.first?.update(targetDraft, manual: true)
                            try? context.save()
                        }.font(.subheadline.bold()).frame(maxWidth: .infinity).frame(minHeight: 44)
                            .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                    }

                    SettingsSection("AI", icon: "sparkles") {
                        statusRow("Food recognition", value: modelStatus("FoodRecognition"))
                        statusRow("Portion estimation", value: modelStatus("FoodPortion"))
                        SecureField("Optional remote API key", text: $apiKey)
                            .textContentType(.password).padding(12)
                            .background(AppTheme.field, in: RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Button("Save Key") {
                                message = SecretStore.save(apiKey) ? "Key stored in Keychain." : "Could not store key."
                                apiKey = ""
                            }.disabled(apiKey.isEmpty)
                            Spacer()
                            Button("Delete Key", role: .destructive) { SecretStore.delete(); message = "Key deleted." }
                        }.font(.subheadline.bold())
                        Toggle("Keep corrected AI results", isOn: $retainCorrections).tint(AppTheme.accent)
                        Text("A key alone does not enable remote analysis; a provider must be configured.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    SettingsSection("Data & Privacy", icon: "externaldrive") {
                        Toggle("Retain analysed images", isOn: $retainImages).tint(AppTheme.accent)
                        Divider()
                        Button { export() } label: { Label("Export Backup", systemImage: "square.and.arrow.up") }
                        Button { showImport = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down") }
                        Button(role: .destructive) { showDelete = true } label: { Label("Delete All Data", systemImage: "trash") }
                    }

                    SettingsSection("About", icon: "info.circle") {
                        Text("Nutrition and photo portions are estimates, not medical advice.")
                            .font(.subheadline)
                        Text("FoodSeg103, Nutrition5k, MyFCD, Open Food Facts, Malaysia Food-11, MF-150 and Roboflow Malaysian Food Recognition.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.appPageContent()
            }
            .scrollDismissesKeyboard(.interactively)
            .appPageSurface()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { AppKeyboard.dismiss() } }
            }
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
                    restore(try BackupService.decode(Data(contentsOf: url)))
                } catch { message = error.localizedDescription }
            }
            .confirmationDialog("Delete all nutrition data?", isPresented: $showDelete) {
                Button("Delete All Data", role: .destructive) { deleteAll() }
            }
            .alert("Settings", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }.tint(AppTheme.accent)
    }

    private func numberRow(_ title: String, unit: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            TextField(title, value: value, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .font(.subheadline.bold()).frame(width: 72)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }.frame(minHeight: 44)
    }
    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.caption.bold()).foregroundStyle(value == "Installed" ? AppTheme.accent : Color.secondary)
        }.frame(minHeight: 36)
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
