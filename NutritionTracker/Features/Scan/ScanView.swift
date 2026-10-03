import SwiftUI
import SwiftData
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(VisionKit)
import VisionKit
#endif

/// Exactly three actions: Take Photo, Choose Photo, Scan Barcode
/// (spec section 16).
///
/// Every capture ends in Add Meal with a prefilled draft. The review step is
/// Add Meal itself, so Scan never holds a result of its own: one photo or one
/// barcode in, one draft out. When nothing could be filled in (no model
/// installed, product unknown, offline), the user still lands in Add Meal with
/// whatever is known and a note explaining why.
struct ScanView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @State private var mode: Mode = .idle
    @State private var pipeline: PhotoAnalysisPipeline?
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoPickerPresented = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var isShowingModelUnavailable = false

    enum Mode: Equatable {
        case idle
        case camera
        case barcode
        case analysing
        case lookingUpBarcode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    switch mode {
                    case .analysing:
                        analysingSection
                    case .lookingUpBarcode:
                        lookingUpSection
                    default:
                        actionsSection
                    }
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            #if canImport(UIKit)
            .fullScreenCover(isPresented: Binding(
                get: { mode == .camera },
                set: { if !$0, mode == .camera { mode = .idle } })) {
                cameraCover
            }
            #endif
            #if canImport(VisionKit)
            .fullScreenCover(isPresented: Binding(
                get: { mode == .barcode },
                set: { if !$0, mode == .barcode { mode = .idle } })) {
                barcodeCover
            }
            #endif
            // Single image only (spec section 17).
            .photosPicker(isPresented: $photoPickerPresented,
                          selection: $photoSelection,
                          matching: .images)
            // Only for failures where nothing was captured at all (camera
            // could not start, unreadable file). Anything captured goes to
            // Add Meal instead.
            .alert("Something went wrong",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: photoSelection) { _, newValue in
                guard let newValue else { return }
                Task { await loadFromLibrary(item: newValue) }
            }
            .alert("Model not available", isPresented: $isShowingModelUnavailable) {
                Button("Add by Hand") {
                    router.present(drafts: [FoodEntryDraft()])
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Recognising food from photos isn't available in this version of "
                     + "the app. You can still scan a barcode or add food by hand.")
            }
            .onAppear {
                if pipeline == nil {
                    pipeline = PhotoAnalysisPipeline.make(context: context)
                }
            }
        }
    }

    // MARK: Sections

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Photographing a meal is the main thing this tab is for.
            ScanTile(title: "Take Photo",
                     detail: "Photograph your meal and get an estimate",
                     systemImage: "camera.fill",
                     style: .hero) {
                requirePhotoModel { mode = .camera }
            }

            HStack(spacing: 14) {
                ScanTile(title: "Choose Photo",
                         detail: "From your library",
                         systemImage: "photo.on.rectangle") {
                    requirePhotoModel { photoPickerPresented = true }
                }
                ScanTile(title: "Scan Barcode",
                         detail: "Packaged food",
                         systemImage: "barcode.viewfinder") {
                    mode = .barcode
                }
            }

            Text("Whatever you capture opens in Add Meal with the details filled in. "
                 + "Photo estimates come from a single photo, so check them before saving.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var analysingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LoadingAnalysisView(stage: pipeline?.stage ?? .preparingImage)
            Button("Cancel") {
                analysisTask?.cancel()
                mode = .idle
            }
            .buttonStyle(.appSecondary)
        }
    }

    private var lookingUpSection: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Looking up product\u{2026}")
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .appCard()
        .accessibilityElement(children: .combine)
    }

    /// Photo actions need Model A. Instead of showing model status anywhere,
    /// the user is told it's unavailable at the moment they try to use it.
    private func requirePhotoModel(then start: () -> Void) {
        if pipeline?.canRecogniseFoods == true {
            start()
        } else {
            isShowingModelUnavailable = true
        }
    }

    // MARK: Covers

    #if canImport(UIKit)
    @ViewBuilder
    private var cameraCover: some View {
        let permission = CameraPermission.current()
        if let explanation = permission.explanation {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    ErrorStateView(title: "Camera unavailable", message: explanation)
                    Button("Close") { mode = .idle }
                        .buttonStyle(.appPrimary)
                }
                .padding()
            }
        } else {
            CameraPicker(onImage: { image in
                startAnalysis(image: image)
            }, onCancel: {
                mode = .idle
            })
            .ignoresSafeArea()
        }
    }
    #endif

    #if canImport(VisionKit)
    @ViewBuilder
    private var barcodeCover: some View {
        ZStack(alignment: .bottom) {
            if BarcodeScannerView.isSupported {
                BarcodeScannerView(onBarcode: { value in
                    Task { await lookUp(barcode: value) }
                }, onError: { message in
                    mode = .idle
                    errorMessage = message
                })
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ErrorStateView(
                    title: "Scanning unavailable",
                    message: "This device cannot scan barcodes with the camera. "
                        + "You can add the product by hand instead.")
            }

            VStack(spacing: 10) {
                Text("Point the camera at a barcode")
                    .font(.footnote)
                    .foregroundStyle(.white)
                Button("Cancel") { mode = .idle }
                    .buttonStyle(.appPrimary)
            }
            .padding(.bottom, 32)
        }
    }
    #endif

    // MARK: Photo flow

    private func loadFromLibrary(item: PhotosPickerItem) async {
        photoSelection = nil
        #if canImport(UIKit)
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "That image could not be read. Try a different photo."
            return
        }
        startAnalysis(image: image)
        #endif
    }

    #if canImport(UIKit)
    private func startAnalysis(image: UIImage) {
        guard let pipeline else {
            mode = .idle
            return
        }
        // Closes the camera cover and shows progress in one step.
        mode = .analysing

        analysisTask = Task {
            let retain = context.loadAppSettings().retainAnalysedImages
            do {
                let result = try await pipeline.analyse(image: image, retainImage: retain)
                guard !Task.isCancelled else { return }
                handOver(photoResult: result)
            } catch is CancellationError {
                mode = .idle
            } catch {
                guard !Task.isCancelled else { return }
                // Analysis failed, but a photo was taken: open Add Meal anyway
                // so the user can enter the meal by hand (spec section 25).
                Haptics.warning()
                router.present(drafts: [FoodEntryDraft(source: .manual)],
                               notice: Self.photoFailureNotice(for: error))
                mode = .idle
            }
        }
    }
    #endif

    private func handOver(photoResult result: PhotoAnalysisResult) {
        if result.isEmpty {
            Haptics.warning()
            router.present(
                drafts: [FoodEntryDraft(source: .photoAI, photoPath: result.photoPath)],
                notice: "No food could be recognised in that photo. Enter the meal below.")
        } else {
            Haptics.success()
            var notice = "Filled in from your photo. Portions and nutrition are "
                + "estimates; check each amount before saving."
            if result.detections.contains(where: \.isLowConfidence) {
                notice += " Items marked with a percentage were hard to identify."
            }
            if !result.portionsEstimated {
                // Model B missing: say so where it matters, on the amounts.
                notice = "Foods recognised from your photo. The portion model isn't "
                    + "available, so the amounts are rough defaults; set each one "
                    + "before saving."
            }
            router.present(drafts: [result.makeDraft()], notice: notice)
        }
        mode = .idle
    }

    static func photoFailureNotice(for error: Error) -> String {
        if let aiError = error as? AIServiceError, aiError.isModelUnavailable {
            return "The food recognition model isn't available, so nothing could be "
                + "recognised. Enter the meal below."
        }
        return "The photo couldn't be analysed (\(error.localizedDescription)). "
            + "Enter the meal below."
    }

    // MARK: Barcode flow

    private func lookUp(barcode: String) async {
        mode = .lookingUpBarcode
        defer { mode = .idle }

        let service = BarcodeLookupService(context: context)
        let outcome: BarcodeLookupService.Outcome
        do {
            outcome = try await service.lookup(barcode: barcode)
        } catch {
            // Offline or the database errored: still open Add Meal, keyed to the
            // barcode, so whatever the user types is remembered for next time.
            Haptics.warning()
            router.present(drafts: [Self.manualBarcodeDraft(barcode)],
                           notice: "Couldn't reach the product database for barcode "
                               + "\(barcode). Enter the details from the label; they'll "
                               + "be remembered for this barcode.")
            return
        }

        switch outcome {
        case .found(let product, let fromCache):
            Haptics.success()
            let source = fromCache ? "a product you've scanned before"
                                   : "Open Food Facts"
            router.present(drafts: [product.makeDraft()],
                           notice: "Filled in from \(source), per "
                               + "\(AppFormatters.amount(product.servingSize)) \(product.unit.shortLabel). "
                               + "Check it against the label and set how much you had.")

        case .notFound(let code):
            Haptics.warning()
            router.present(drafts: [Self.manualBarcodeDraft(code)],
                           notice: "Barcode \(code) isn't in Open Food Facts yet. Enter "
                               + "the details from the label; they'll be remembered for "
                               + "next time.")
        }
    }

    /// A blank product keyed to the barcode, in grams per 100 g like a label.
    static func manualBarcodeDraft(_ barcode: String) -> FoodEntryDraft {
        FoodEntryDraft(quantity: 100, servingSize: 100, unit: .gram,
                       source: .barcode, barcode: barcode)
    }
}

/// A Scan action. The hero style is the large primary tile; compact tiles sit
/// two to a row.
struct ScanTile: View {
    enum Style { case hero, compact }

    let title: String
    let detail: String
    let systemImage: String
    var style: Style = .compact
    let action: () -> Void

    private var isHero: Bool { style == .hero }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: isHero ? 14 : 10) {
                Image(systemName: systemImage)
                    .font(.system(size: isHero ? 26 : 20, weight: .semibold))
                    .frame(width: isHero ? 58 : 44, height: isHero ? 58 : 44)
                    .foregroundStyle(isHero ? AppTheme.onAccent : AppTheme.accent)
                    .background(isHero ? AppTheme.accentFill : AppTheme.subtleFill, in: Circle())
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(isHero ? .title3.weight(.bold) : .headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(isHero ? 20 : 16)
            .frame(maxWidth: .infinity, minHeight: isHero ? 190 : 140, alignment: .leading)
            .background(isHero ? AppTheme.skyCard : AppTheme.cardBackground,
                        in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(ScanTilePressStyle())
        .accessibilityLabel("\(title). \(detail)")
    }
}

/// Slight shrink while pressed, so the tiles feel like buttons.
private struct ScanTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
