import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings (spec section 29).
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [UserProfile]
    @Query private var targets: [NutritionTarget]

    @State private var isShowingProfileEditor = false
    @State private var isShowingTargetsEditor = false
    @State private var isShowingExporter = false
    @State private var isShowingImporter = false
    @State private var exportURL: URL?
    @State private var importSummary: String?
    @State private var alertMessage: String?
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingImport: BackupFile?

    private var settings: AppSettings { context.loadAppSettings() }
    private var profile: UserProfile? { profiles.first }
    private var target: NutritionTarget? {
        targets.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    rangeSummarySection
                    profileSection
                    targetsSection
                    dataSection
                    aboutSection
                }
                // Soft card rows instead of the system's pure white.
                .listRowBackground(AppTheme.cardBackground)
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingProfileEditor) {
                if let profile { ProfileEditorView(profile: profile) }
            }
            .sheet(isPresented: $isShowingTargetsEditor) {
                if let target { TargetsEditorView(target: target) }
            }
            .fileImporter(isPresented: $isShowingImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleImportSelection(result)
            }
            .alert("Backup", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } })) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .alert("Restore this backup?", isPresented: Binding(
                get: { isConfirmingImport != nil },
                set: { if !$0 { isConfirmingImport = nil } })) {
                Button("Replace all data", role: .destructive) {
                    if let file = isConfirmingImport { performImport(file, strategy: .replace) }
                    isConfirmingImport = nil
                }
                Button("Merge into current data") {
                    if let file = isConfirmingImport { performImport(file, strategy: .merge) }
                    isConfirmingImport = nil
                }
                Button("Cancel", role: .cancel) { isConfirmingImport = nil }
            } message: {
                if let file = isConfirmingImport {
                    Text("The backup holds \(file.foodEntries.count) food entries "
                         + "from \(AppFormatters.shortDay.string(from: file.exportDate)). "
                         + "Replacing deletes what is currently on this device.")
                }
            }
            .alert("Delete all data?", isPresented: $isConfirmingDeleteAll) {
                Button("Delete everything", role: .destructive) { deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your profile, targets, every food entry and all "
                     + "retained photos from this iPhone. It cannot be undone. "
                     + "Export a backup first if you might want this data back.")
            }
        }
    }

    // MARK: Range summary

    /// Pale blue card at the top: today's calorie range and the profile it
    /// came from.
    private var rangeSummarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR DAILY RANGE")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.skyCardText)
                if let target {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(AppFormatters.range(target.ranges.calories))
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("kcal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.skyCardText)
                    }
                } else {
                    Text("No targets yet")
                        .font(.title3.weight(.bold))
                }
                if let profile {
                    Text("\(profile.goal.displayName) \u{00B7} "
                         + "\(AppFormatters.amount(profile.heightCm)) cm \u{00B7} "
                         + "\(AppFormatters.amount(profile.weightKg)) kg")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.skyCardText)
                }
            }
            .appSkyCard()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section("Profile") {
            if let profile {
                LabeledContent("Goal", value: profile.goal.displayName)
                LabeledContent("Activity", value: profile.activity.displayName)
                LabeledContent("Weight",
                               value: "\(AppFormatters.amount(profile.weightKg)) kg")
                LabeledContent("Height",
                               value: "\(AppFormatters.amount(profile.heightCm)) cm")

                Button("Edit profile") { isShowingProfileEditor = true }

                Button("Recalculate targets") { recalculateTargets() }

                if profile.targetsLikelyStale {
                    // Targets are never silently recalculated; the user is just
                    // told that they look stale (spec section 6).
                    Label("Your profile has changed since these targets were "
                          + "worked out. Recalculating is optional.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No profile yet.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Targets

    private var targetsSection: some View {
        Section {
            if let target {
                ForEach(Nutrient.allCases) { nutrient in
                    let range = target.ranges[nutrient]
                    LabeledContent(nutrient.displayName) {
                        HStack(spacing: 4) {
                            Text("\(AppFormatters.range(range)) \(nutrient.unitLabel)")
                                .monospacedDigit()
                            if range.isManuallyModified {
                                Image(systemName: "pencil")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Edited by you")
                            }
                        }
                    }
                }
                Button("Edit daily ranges") { isShowingTargetsEditor = true }
            } else {
                Text("No targets yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Daily Targets")
        } footer: {
            Text("Each nutrient is a range with a minimum and a maximum, because "
                 + "the formulas behind them are estimates. Edit either bound.")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            Toggle("Keep analysed photos",
                   isOn: Binding(
                    get: { settings.retainAnalysedImages },
                    set: { newValue in
                        settings.retainAnalysedImages = newValue
                        if !newValue { ImageStore.deleteAll() }
                        save()
                    }))
            .tint(AppTheme.nativeSwitch)

            Toggle("Keep my corrections for future training",
                   isOn: Binding(
                    get: { settings.storeCorrectionsForTraining },
                    set: { settings.storeCorrectionsForTraining = $0; save() }))
            .tint(AppTheme.nativeSwitch)

            Button("Export backup") { exportBackup() }

            Button("Import backup") { isShowingImporter = true }

            if let importSummary {
                Text(importSummary).font(.caption).foregroundStyle(.secondary)
            }

            Button("Delete all data", role: .destructive) {
                isConfirmingDeleteAll = true
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Everything is stored on this iPhone only. Deleting the app "
                 + "removes its database, so export a backup if that matters. "
                 + "Corrections and photos are never uploaded anywhere.")
        }
        .sheet(isPresented: $isShowingExporter) {
            if let exportURL {
                ShareSheet(url: exportURL)
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.versionString)
            LabeledContent("Food reference rows",
                           value: "\(LocalNutritionReference.shared.count)")
            LabeledContent("Ontology entries", value: "\(FoodOntology.shared.count)")

            NavigationLink("Data sources and licences") { AttributionView() }
        } header: {
            Text("About")
        } footer: {
            Text("Calculated targets and image-based nutrition estimates are "
                 + "informational only and are not medical advice.")
        }
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: Actions

    private func save() {
        try? context.save()
    }

    private func recalculateTargets() {
        guard let profile else { return }
        let breakdown = NutritionTargetCalculator.calculate(profile: profile)
        if let target {
            // Preserves bounds the user edited by hand.
            target.apply(recalculated: breakdown.ranges)
        } else {
            context.insert(NutritionTarget(ranges: breakdown.ranges))
        }
        profile.markTargetsCalculated()
        save()
        Haptics.success()
        alertMessage = "Targets recalculated. Any bound you edited by hand was kept."
    }

    private func exportBackup() {
        do {
            exportURL = try BackupService(context: context).exportToTemporaryFile()
            isShowingExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertMessage = error.localizedDescription

        case .success(let urls):
            guard let url = urls.first else { return }
            // Security-scoped: the picker hands back a URL outside the sandbox.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                alertMessage = BackupError.unreadableFile.localizedDescription
                return
            }
            do {
                // Validated before anything touches the database.
                isConfirmingImport = try BackupService.validate(data: data)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func performImport(_ file: BackupFile, strategy: BackupService.ImportStrategy) {
        do {
            let summary = try BackupService(context: context)
                .importBackup(file, strategy: strategy)
            importSummary = "Imported \(summary.entriesImported) entries"
                + (summary.entriesSkipped > 0
                   ? ", skipped \(summary.entriesSkipped) already present" : "")
                + "."
            Haptics.success()
        } catch {
            alertMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func deleteAll() {
        BackupService(context: context).deleteAllData(includingImages: true)
        LegacySecretCleanup.deleteStoredKeys()
        let settings = context.loadAppSettings()
        settings.hasCompletedOnboarding = false
        save()
        Haptics.success()
        dismiss()
    }
}

// MARK: - Editors

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var profile: UserProfile

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("Body") {
                        DatePicker("Date of birth", selection: $profile.dateOfBirth,
                                   displayedComponents: .date)
                        SliderEntryRow(title: "Height", value: $profile.heightCm,
                                       range: 120...220, step: 1, unitLabel: "cm")
                        SliderEntryRow(title: "Weight", value: $profile.weightKg,
                                       range: 30...200, step: 0.5, unitLabel: "kg",
                                       fractionDigits: 1)
                        Picker("Sex", selection: Binding(
                            get: { profile.sex }, set: { profile.sex = $0 })) {
                            ForEach(BiologicalSex.allCases) { Text($0.displayName).tag($0) }
                        }
                    }

                    Section("Goal") {
                        Picker("Goal", selection: Binding(
                            get: { profile.goal }, set: { profile.goal = $0 })) {
                            ForEach(FitnessGoal.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("Activity", selection: Binding(
                            get: { profile.activity }, set: { profile.activity = $0 })) {
                            ForEach(ActivityLevel.allCases) { Text($0.displayName).tag($0) }
                        }
                    }

                    Section("Training") {
                        SliderEntryRow(title: "Strength sessions per week",
                                       value: Binding(
                                        get: { Double(profile.strengthSessionsPerWeek) },
                                        set: { profile.strengthSessionsPerWeek = Int($0.rounded()) }),
                                       range: 0...14, step: 1)
                        SliderEntryRow(title: "Cardio sessions per week",
                                       value: Binding(
                                        get: { Double(profile.cardioSessionsPerWeek) },
                                        set: { profile.cardioSessionsPerWeek = Int($0.rounded()) }),
                                       range: 0...14, step: 1)
                    }
                }
                // Soft card rows instead of the system's pure white.
                .listRowBackground(AppTheme.cardBackground)
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TargetsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let target: NutritionTarget
    @State private var ranges = NutritionTargetRanges.zero

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppTheme.pageSpacing) {
                    ForEach(Nutrient.allCases) { nutrient in
                        RangeEditorRow(nutrient: nutrient,
                                       range: Binding(
                                        get: { ranges[nutrient] },
                                        set: { ranges[nutrient] = $0 }))
                    }
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Daily ranges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        target.ranges = ranges
                        try? context.save()
                        Haptics.success()
                        dismiss()
                    }
                }
            }
            .onAppear { ranges = target.ranges }
        }
    }
}

/// Attribution for every dataset and database the app relies on
/// (spec sections 29, 38).
struct AttributionView: View {
    var body: some View {
        List {
            Group {
                Section("Nutrition data") {
                    AttributionRow(
                        title: "MyFCD \u{2014} Malaysian Food Composition Database",
                        detail: "Ministry of Health Malaysia. Lab-measured values for "
                            + "local foods, compiled by hand into the bundled reference "
                            + "table. Check its terms before redistributing.")
                    AttributionRow(
                        title: "Open Food Facts",
                        detail: "Barcode product data, contributed by the community. "
                            + "Product data under the Open Database Licence (ODbL).")
                }

                Section("Model training datasets") {
                    AttributionRow(
                        title: "FoodSeg103",
                        detail: "Food segmentation base training set for Model A. "
                            + "Research use; check its licence before distribution.")
                    AttributionRow(
                        title: "Nutrition5k",
                        detail: "Google. Mass and nutrition labels for Model B. "
                            + "Captured on a fixed overhead rig with depth sensing.")
                    AttributionRow(
                        title: "Malaysia Food-11",
                        detail: "Kaggle. Small 11-class Malaysian starter set, "
                            + "used for fine-tuning.")
                    AttributionRow(
                        title: "MF-150",
                        detail: "IEEE DataPort. Multilabel Malaysian foods dataset for "
                            + "ingredient detection.")
                    AttributionRow(
                        title: "Malaysian Food Recognition 1 & 2",
                        detail: "Roboflow Universe, CC BY 4.0. Community "
                            + "object-detection sets.")
                }

                Section {
                    Text("Local-dish recognition starts weak: the public Malaysian "
                         + "datasets are small, and Model B's portion estimates were "
                         + "trained only on Nutrition5k, so its accuracy on local "
                         + "food is unverified. Your own corrections are what "
                         + "improve it over time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Accuracy")
                }
            }
            // Soft card rows instead of the system's pure white.
            .listRowBackground(AppTheme.cardBackground)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Data sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AttributionRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

#if canImport(UIKit)
/// Native share sheet for the exported backup file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
