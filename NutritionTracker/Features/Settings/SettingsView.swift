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
    @AppStorage("appearance") private var appearance = AppAppearance.light.rawValue
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingImport: BackupFile?
    @State private var healthNotes: [HealthNote] = []

    private var settings: AppSettings { context.loadAppSettings() }
    private var profile: UserProfile? { profiles.first }
    private var target: NutritionTarget? {
        targets.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    var body: some View {
        NavigationStack {
            Form {
                // Tinted, like the mockup's plan card.
                summarySection
                Group {
                    planSection
                    appearanceSection
                    assistantSection
                    healthSection
                    backupSection
                    aboutSection
                }
                // Soft card rows instead of the system's pure white.
                .listRowBackground(AppTheme.cardBackground)
                // Clear row: the button draws its own outlined capsule.
                deleteSection
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            // A sheet is its own presentation and doesn't pick up a change
            // made at the root while it's open, so Settings - where the
            // picker lives - applies the choice to itself as well.
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.resolvedColorScheme)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { healthNotes = HealthNotesStore.shared.notes }
            .sheet(isPresented: $isShowingProfileEditor) {
                if let profile { ProfileEditorView(profile: profile) }
            }
            .sheet(isPresented: $isShowingTargetsEditor) {
                if let target { TargetsEditorView(target: target) }
            }
            .sheet(isPresented: $isShowingExporter) {
                if let exportURL { ShareSheet(url: exportURL) }
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
                Text("This removes your profile, daily ranges, every food entry and all "
                     + "assistant chats and their photos from this iPhone. It cannot be "
                     + "undone. Export a backup first if you might want this data back.")
            }
        }
    }

    // MARK: Summary

    /// Who the targets are for, and the headline calorie range. The only place
    /// the profile basics are shown, so nothing below repeats them.
    private var summarySection: some View {
        Section {
            Button {
                if profile != nil { isShowingProfileEditor = true }
            } label: {
                HStack(spacing: 14) {
                    AppIconImage(size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        if let profile {
                            Text(profile.goal.displayName)
                                .font(.headline)
                            Text("\(AppFormatters.amount(profile.heightCm)) cm \u{00B7} "
                                 + "\(AppFormatters.amount(profile.weightKg)) kg \u{00B7} "
                                 + profile.activity.displayName)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.skyCardText)
                        } else {
                            Text("No profile yet").font(.headline)
                        }
                        if let target {
                            Text("\(AppFormatters.range(target.ranges.calories)) kcal a day")
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 4)
                    if profile != nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit profile")
            .listRowBackground(AppTheme.skyCard)
        }
    }

    // MARK: Plan

    private var planSection: some View {
        Section {
            SettingsRow(title: "Profile", systemImage: "person",
                        detail: profile.map { "Goal, body and activity \u{00B7} \($0.age()) yrs" }) {
                isShowingProfileEditor = true
            }
            .disabled(profile == nil)

            SettingsRow(title: "Daily ranges", systemImage: "target",
                        detail: targetsDetail) {
                isShowingTargetsEditor = true
            }
            .disabled(target == nil)
        } header: {
            Text("Your plan")
        } footer: {
            Text("Your daily ranges update automatically when you change your profile. "
                 + "Any value you edited by hand is kept.")
        }
    }

    private var targetsDetail: String? {
        guard let target else { return nil }
        let edited = Nutrient.allCases.filter { target.ranges[$0].isManuallyModified }.count
        return edited == 0 ? "Calculated for you" : "\(edited) edited by you"
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Light uses a warm paper palette, soft charcoal text and no pure "
                 + "white or black, which is easier on the eyes.")
        }
    }

    // MARK: AI assistant

    /// Which AI answers, and what it is sent - the one part of the app that
    /// leaves the phone.
    private var assistantSection: some View {
        Section {
            LabeledContent {
                Text(Self.assistantModelName)
            } label: {
                SettingsLabel("Model", systemImage: "sparkles")
            }
            LabeledContent {
                Text("Low")
            } label: {
                SettingsLabel("Reasoning effort", systemImage: "brain")
            }
        } header: {
            Text("AI assistant")
        } footer: {
            Text("To answer, the assistant sends OpenAI your message, any photos you attach, "
                 + "your profile basics, daily ranges, health notes and recent food log. "
                 + "Searches for food, brands and places also go through OpenAI. Chats are "
                 + "kept on this iPhone under Past chats.")
        }
    }

    // MARK: Health notes

    /// Conditions the assistant takes into account, usually saved from a
    /// check-up report sent in the chat. Swipe one to delete it.
    private var healthSection: some View {
        Section {
            if healthNotes.isEmpty {
                Text("None yet. Send the assistant a photo of a check-up report, or tell it "
                     + "about a condition such as prediabetes or high uric acid, and it can "
                     + "save notes that shape its advice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(healthNotes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.condition)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        if !note.details.isEmpty {
                            Text(note.details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(note.guidance, id: \.self) { rule in
                            Text("\u{2022} \(rule)")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    for index in offsets { HealthNotesStore.shared.delete(id: healthNotes[index].id) }
                    healthNotes = HealthNotesStore.shared.notes
                }
            }
        } header: {
            Text("Health notes")
        } footer: {
            Text("Kept on this iPhone. Guidance for the assistant, not medical advice - "
                 + "always follow your doctor's.")
        }
    }

    /// "GPT-6 Luna" for the default model, else the configured model's id.
    static var assistantModelName: String {
        let model = BundledAPIKey.assistantModel ?? OpenAIAssistantService.defaultModel
        return model == "gpt-6-luna" ? "GPT-6 Luna" : model
    }

    // MARK: Backup

    private var backupSection: some View {
        Section {
            Button { exportBackup() } label: {
                SettingsLabel("Export backup", systemImage: "square.and.arrow.up")
            }
            Button { isShowingImporter = true } label: {
                SettingsLabel("Import backup", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text(importSummary ?? "Deleting the app deletes its data, so export a backup "
                 + "before you uninstall or switch phones.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(Self.versionString).monospacedDigit()
            } label: {
                SettingsLabel("Version", systemImage: "info.circle")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Daily ranges and AI nutrition figures are estimates for information "
                 + "only, not medical advice.")
        }
    }

    // MARK: Delete

    /// On its own at the bottom, away from everyday options.
    private var deleteSection: some View {
        Section {
            // An outlined capsule on the page rather than a list row.
            Button(role: .destructive) {
                isConfirmingDeleteAll = true
            } label: {
                Text("Delete all data")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.destructiveText)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .overlay(Capsule().stroke(AppTheme.destructiveText.opacity(0.3), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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
        ChatHistoryStore.shared.deleteAll()
        HealthNotesStore.shared.deleteAll()
        let settings = context.loadAppSettings()
        settings.hasCompletedOnboarding = false
        save()
        Haptics.success()
        dismiss()
    }
}

// MARK: - Rows

/// A tappable Settings row: icon, title, optional one-line subtitle, chevron.
/// Opens its editor as a sheet, so it is a button styled like a navigation row.
/// The 32 pt tinted tile every Settings row's symbol sits in.
struct SettingsIconTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .frame(width: 32, height: 32)
            .background(AppTheme.skyCard, in: RoundedRectangle(
                cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A Settings row title with its icon tile, for toggles and plain buttons.
struct SettingsLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIconTile(systemImage: systemImage)
        }
    }
}

struct SettingsRow: View {
    let title: String
    let systemImage: String
    var detail: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    SettingsIconTile(systemImage: systemImage)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Editors

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var profile: UserProfile

    /// What the targets were last calculated from, captured when the editor
    /// opens, so closing it only recalculates if something relevant changed.
    @State private var originalInputs: TargetInputs?

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
                        Toggle("I have a target weight", isOn: Binding(
                            get: { profile.targetWeightKg != nil },
                            set: { profile.targetWeightKg = $0 ? profile.weightKg : nil }))
                            .tint(AppTheme.nativeSwitch)
                        if profile.targetWeightKg != nil {
                            SliderEntryRow(title: "Target weight", value: Binding(
                                get: { profile.targetWeightKg ?? profile.weightKg },
                                set: { profile.targetWeightKg = $0 }),
                                           range: 30...200, step: 0.5, unitLabel: "kg",
                                           fractionDigits: 1)
                        }
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
                        TrainingDaysEditor(strengthDays: $profile.strengthSessionsPerWeek,
                                           cardioDays: $profile.cardioSessionsPerWeek)
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
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { originalInputs = TargetInputs(profile) }
        // Runs however the sheet closes - Done or a swipe down.
        .onDisappear {
            if let originalInputs, originalInputs != TargetInputs(profile) {
                TargetUpdater.update(for: profile, in: context)
            } else {
                try? context.save()
            }
        }
    }
}

/// The profile fields the daily targets are calculated from (spec section 6).
/// Training days are deliberately absent: they don't change the maths.
struct TargetInputs: Equatable {
    let dateOfBirth: Date
    let sex: BiologicalSex
    let heightCm: Double
    let weightKg: Double
    let goal: FitnessGoal
    let activity: ActivityLevel
    /// Sets protein and the fat floor at a BMI of 30 or more.
    let targetWeightKg: Double?

    init(_ profile: UserProfile) {
        dateOfBirth = profile.dateOfBirth
        sex = profile.sex
        heightCm = profile.heightCm
        weightKg = profile.weightKg
        goal = profile.goal
        activity = profile.activity
        targetWeightKg = profile.targetWeightKg
    }
}

/// Keeps the daily targets in step with the profile.
@MainActor
enum TargetUpdater {
    /// Recalculates and saves the targets. Any bound the user edited by hand
    /// is kept, so an automatic update never undoes a deliberate choice.
    static func update(for profile: UserProfile, in context: ModelContext) {
        let ranges = NutritionTargetCalculator.calculate(profile: profile).ranges
        if let target = context.loadNutritionTarget() {
            target.apply(recalculated: ranges)
        } else {
            context.insert(NutritionTarget(ranges: ranges))
        }
        profile.markTargetsCalculated()
        try? context.save()
    }
}

struct TargetsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let target: NutritionTarget
    @Query private var profiles: [UserProfile]
    @State private var ranges = NutritionTargetRanges.zero

    /// What the profile works out to now, to compare with and reset to.
    private var calculated: NutritionTargetRanges? {
        profiles.first.map { NutritionTargetCalculator.calculate(profile: $0).ranges }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    Text("Each target is a range: a minimum to reach every day and a "
                         + "maximum not to go over. Tap one to change either end.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        ForEach(Nutrient.allCases) { nutrient in
                            RangeEditorRow(nutrient: nutrient,
                                           range: Binding(
                                            get: { ranges[nutrient] },
                                            set: { ranges[nutrient] = $0 }),
                                           calculated: calculated?[nutrient])
                        }
                    }

                    Text("Ranges you change here stay as you set them when your profile "
                         + "changes. The others are recalculated for you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .appPageContent()
            }
            .keyboardDismissControls()
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
