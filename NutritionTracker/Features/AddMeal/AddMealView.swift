import SwiftUI
import SwiftData

/// Add Meal holds one or more draft food cards before saving (spec section 12).
///
/// It always shows at least one card: the page opens with a blank one ready to
/// fill in, and the last card can't be removed. It is also the mandatory review
/// step for the photo pipeline, barcode scanning and the assistant, all of which
/// hand over drafts rather than writing to the database.
struct AddMealView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @State private var drafts: [FoodEntryDraft] = [FoodEntryDraft()]
    @State private var saveError: String?
    /// Explanation handed over with scanned or photographed drafts.
    @State private var notice: String?

    /// Default is now; changing it relabels the save button.
    private var isBackdated: Bool {
        guard let first = drafts.first else { return false }
        return !LocalDay.isToday(first.consumedAt)
    }

    private var combinedTotal: Nutrition {
        drafts.reduce(.zero) { $0 + $1.total }
    }

    private var canSave: Bool {
        drafts.allSatisfy(\.isSaveable)
    }

    /// One time for the whole meal, applied to every food on the page.
    private var mealTime: Binding<Date> {
        Binding(
            get: { drafts.first?.consumedAt ?? .now },
            set: { time in
                for index in drafts.indices { drafts[index].consumedAt = time }
            })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    PageHeader(title: "Add meal")

                    if let notice {
                        noticeCard(notice)
                    } else if drafts.contains(where: { $0.source == .photoAI }) {
                        // The hand-over notice already says this, so only one shows.
                        EstimateDisclaimer().appCard()
                    }

                    ForEach($drafts) { $draft in
                        FoodDraftCard(draft: $draft,
                                      onDelete: deleteAction(for: draft.id))
                    }

                    DashedAddButton(title: "Add another food") { addCard() }

                    DatePicker("Eaten at", selection: mealTime,
                               in: ...Date.now.addingTimeInterval(60 * 60),
                               displayedComponents: [.date, .hourAndMinute])
                        .font(.subheadline.weight(.semibold))
                        .appCard()

                    // The whole meal's calories, always; the macro tiles join
                    // them once there is more than one food to add up.
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Meal total")
                                .font(.subheadline.weight(.heavy))
                            if drafts.count > 1 {
                                Text("\(drafts.count) foods")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.skyCardText)
                            }
                            Spacer()
                            Text(AppFormatters.amount(combinedTotal.calories))
                                .font(.system(.title3, design: .rounded).weight(.heavy))
                                .monospacedDigit()
                            Text("kcal")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppTheme.skyCardText)
                        }
                        if drafts.count > 1 {
                            NutritionSummaryView(nutrition: combinedTotal)
                        }
                    }
                    .appSkyCard()
                }
                .appPageContent()
            }
            .appPageSurface()
            // The title is drawn in the page, like every tab.
            .toolbar(.hidden, for: .navigationBar)
            .keyboardDismissControls()
            .safeAreaInset(edge: .bottom) { saveBar }
            .alert("Could not save",
                   isPresented: Binding(get: { saveError != nil },
                                        set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .onAppear(perform: collectPendingDrafts)
        .onChange(of: router.pendingDrafts.count) { _, _ in collectPendingDrafts() }
    }

    // MARK: Pieces

    private func noticeCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                withAnimation(.snappy) { notice = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .appCard()
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            Button {
                save()
            } label: {
                Text(isBackdated ? "Save to selected date" : "Save to today")
            }
            .buttonStyle(.appPrimary)
            .disabled(!canSave)

            Text(canSave
                 ? "Nutrition and portions are estimates. Review before saving."
                 : "Give every food a name and some nutrition to save.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppTheme.cardPadding + 4)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // A solid bar, so cards scrolling underneath never show through the
        // button. A thin line marks where the page ends.
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Actions

    /// Picks up drafts handed over by Scan or the assistant.
    private func collectPendingDrafts() {
        let pending = router.consumePendingDrafts()
        guard !pending.drafts.isEmpty else { return }

        if drafts.allSatisfy(\.isBlank) {
            // Replace the empty starter card rather than stacking above it.
            drafts = pending.drafts
        } else {
            // Join the meal already being built, at its time, newest first so
            // the card that was just filled in is at the top of the screen.
            let time = mealTime.wrappedValue
            drafts.insert(contentsOf: pending.drafts.map { draft in
                var draft = draft
                draft.consumedAt = time
                return draft
            }, at: 0)
        }
        notice = pending.notice
    }

    private func addCard() {
        // A new card joins the meal at the time already set.
        withAnimation(.snappy) {
            drafts.append(FoodEntryDraft(consumedAt: mealTime.wrappedValue))
        }
        Haptics.selection()
    }

    /// Nil hides "Remove food" when this is the only card left.
    private func deleteAction(for id: UUID) -> (() -> Void)? {
        guard drafts.count > 1 else { return nil }
        return { remove(id: id) }
    }

    private func remove(id: UUID) {
        // The page always keeps one card.
        guard drafts.count > 1 else { return }
        withAnimation(.snappy) { drafts.removeAll { $0.id == id } }
        Haptics.selection()
    }

    private func save() {
        guard canSave else { return }
        let keepCorrections = context.loadAppSettings().storeCorrectionsForTraining
        let encoder = JSONEncoder()
        for draft in drafts {
            context.insert(draft.makeEntry())

            // A barcode the database did not know about is cached with what the
            // user typed, so the next scan resolves locally (spec section 27).
            if draft.source == .barcode, let barcode = draft.barcode, !draft.isComposite,
               context.fetchCachedProduct(barcode: barcode) == nil {
                BarcodeLookupService(context: context).cache(
                    product: BarcodeProduct(barcode: barcode,
                                            name: draft.name,
                                            brand: nil,
                                            servingSize: draft.servingSize,
                                            unit: draft.unit,
                                            nutritionPerServing: draft.nutritionPerServing),
                    isUserEntered: true)
            }

            // Pair what the models predicted with what the user confirmed, if
            // they opted in. Stays on-device (spec section 24).
            if keepCorrections,
               let predictionJSON = draft.predictionJSON,
               let correctionJSON = try? encoder.encode(draft) {
                context.insert(CorrectionRecord(predictionJSON: predictionJSON,
                                                correctionJSON: correctionJSON,
                                                photoPath: draft.photoPath))
            }
        }
        do {
            try context.save()
            drafts = [FoodEntryDraft()]
            notice = nil
            Haptics.success()
            router.selectedTab = .dashboard
        } catch {
            Haptics.error()
            saveError = error.localizedDescription
        }
    }
}

