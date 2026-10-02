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
/// Only one photo is ever active. A new photo replaces the current one, with a
/// confirmation once an analysed photo is already waiting.
struct ScanView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

    @State private var mode: Mode = .idle
    @State private var pipeline: PhotoAnalysisPipeline?
    @State private var photoSelection: PhotosPickerItem?

    #if canImport(UIKit)
    @State private var capturedImage: UIImage?
    #endif

    @State private var analysisResult: PhotoAnalysisResult?
    @State private var errorMessage: String?
    @State private var recoverableError: AIServiceError?
    @State private var replacementPending: ReplacementSource?
    @State private var barcodeOutcome: BarcodeOutcome?
    @State private var isLookingUpBarcode = false

    enum Mode: Equatable {
        case idle
        case camera
        case barcode
        case analysing
        case reviewing
    }

    enum ReplacementSource: Identifiable {
        case camera, library, barcode
        var id: String { String(describing: self) }
    }

    enum BarcodeOutcome: Equatable {
        case found(BarcodeProduct, fromCache: Bool)
        case notFound(barcode: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    switch mode {
                    case .analysing:
                        analysingSection
                    case .reviewing:
                        reviewSection
                    default:
                        actionsSection
                    }

                    if let barcodeOutcome {
                        barcodeSection(outcome: barcodeOutcome)
                    }

                    modelStatusSection
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
            .alert("Replace the current photo?",
                   isPresented: Binding(get: { replacementPending != nil },
                                        set: { if !$0 { replacementPending = nil } })) {
                Button("Replace", role: .destructive) {
                    if let source = replacementPending {
                        clearCurrentPhoto()
                        begin(source: source)
                    }
                    replacementPending = nil
                }
                Button("Keep current", role: .cancel) { replacementPending = nil }
            } message: {
                Text("Only one photo can be analysed at a time.")
            }
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
            .onAppear {
                if pipeline == nil {
                    pipeline = PhotoAnalysisPipeline.make(
                        context: context, settings: context.loadAppSettings())
                }
            }
        }
    }

    @State private var photoPickerPresented = false

    // MARK: Sections

    private var actionsSection: some View {
        VStack(spacing: 12) {
            ScanActionButton(title: "Take Photo",
                             detail: "Photograph a meal and estimate what is in it.",
                             systemImage: "camera.fill") {
                request(source: .camera)
            }

            ScanActionButton(title: "Choose Photo",
                             detail: "Pick one photo from your library.",
                             systemImage: "photo.on.rectangle") {
                request(source: .library)
            }

            ScanActionButton(title: "Scan Barcode",
                             detail: "Read a packaged product's label data.",
                             systemImage: "barcode.viewfinder") {
                request(source: .barcode)
            }

            EstimateDisclaimer(
                text: "Photo analysis gives a starting estimate from a single "
                    + "photo. You will review and correct it before anything is saved.")
                .appCard()
        }
    }

    private var analysingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LoadingAnalysisView(stage: pipeline?.stage ?? .preparingImage)
            Button("Cancel", role: .cancel) {
                analysisTask?.cancel()
                mode = .idle
            }
            .buttonStyle(.bordered)
        }
    }

    @State private var analysisTask: Task<Void, Never>?

    @ViewBuilder
    private var reviewSection: some View {
        if let result = analysisResult {
            VStack(alignment: .leading, spacing: 14) {
                if result.isEmpty {
                    EmptyStateView(
                        title: "No food recognised",
                        message: "Nothing in that photo could be identified. "
                            + "You can still add the meal by hand.",
                        systemImage: "questionmark.circle",
                        actionTitle: "Add by hand") {
                        router.present(drafts: [FoodEntryDraft(source: .manual)])
                        reset()
                    }
                    .appCard()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        AppSectionHeading(title: "Detected",
                                          trailing: "\(result.detections.count) items")
                        ForEach(result.resolvedNutrition, id: \.detectionID) { item in
                            HStack(spacing: 8) {
                                Text(item.displayName)
                                    .font(.subheadline)
                                Spacer(minLength: 4)
                                Text("\(AppFormatters.amount(item.grams)) g")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                ConfidenceBadge(confidence: item.confidence)
                            }
                        }
                        if result.usedRemoteFallback {
                            Text("Identified using your configured remote AI provider.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        EstimateDisclaimer()
                    }
                    .appCard()

                    Button {
                        router.present(drafts: [result.makeDraft()])
                        reset()
                    } label: {
                        Text("REVIEW IN ADD MEAL")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Discard photo", role: .destructive) {
                    clearCurrentPhoto()
                    reset()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func barcodeSection(outcome: BarcodeOutcome) -> some View {
        switch outcome {
        case .found(let product, let fromCache):
            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeading(title: "Product found",
                                  trailing: fromCache ? "From cache" : "Open Food Facts")
                Text(product.name).font(.headline)
                if let brand = product.brand {
                    Text(brand).font(.caption).foregroundStyle(.secondary)
                }
                NutritionSummaryView(nutrition: product.nutritionPerServing)
                Text("Per \(AppFormatters.amount(product.servingSize)) \(product.unit.shortLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    router.present(drafts: [product.makeDraft()])
                    barcodeOutcome = nil
                } label: {
                    Text("REVIEW IN ADD MEAL")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .appCard()

        case .notFound(let barcode):
            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeading(title: "Product Not Found")
                Text("Barcode \(barcode) is not in the product database.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Enter Product Manually") {
                    // Prefilled with the barcode so the manual entry gets cached
                    // against it for next time.
                    router.present(drafts: [FoodEntryDraft(
                        quantity: 100, servingSize: 100, unit: .gram,
                        source: .barcode, barcode: barcode)])
                    barcodeOutcome = nil
                }
                .buttonStyle(.borderedProminent)

                Button("Scan Another Barcode") {
                    barcodeOutcome = nil
                    request(source: .barcode)
                }
                .buttonStyle(.bordered)
            }
            .appCard()

        case .failed(let message):
            ErrorStateView(title: "Lookup failed", message: message) {
                barcodeOutcome = nil
                request(source: .barcode)
            }
            .appCard()
        }
    }

    @ViewBuilder
    private var modelStatusSection: some View {
        if let pipeline, !pipeline.hasAnyAnalysisCapability {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .accessibilityHidden(true)
                    Text("Local model unavailable")
                        .font(.subheadline.weight(.semibold))
                }
                Text("No on-device food model is installed in this build, and no "
                     + "remote AI provider is configured. Barcode scanning and "
                     + "manual entry work as normal.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appCard()
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
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        } else {
            CameraPicker(onImage: { image in
                capturedImage = image
                mode = .idle
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
                    mode = .idle
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
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 32)
        }
    }
    #endif

    // MARK: Flow

    private func request(source: ReplacementSource) {
        // Confirm before discarding a photo that has already been analysed.
        if analysisResult != nil, source != .barcode {
            replacementPending = source
            return
        }
        begin(source: source)
    }

    private func begin(source: ReplacementSource) {
        barcodeOutcome = nil
        switch source {
        case .camera:
            mode = .camera
        case .library:
            photoPickerPresented = true
        case .barcode:
            mode = .barcode
        }
    }

    private func loadFromLibrary(item: PhotosPickerItem) async {
        photoSelection = nil
        #if canImport(UIKit)
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "That image could not be read. Try a different photo."
            return
        }
        capturedImage = image
        startAnalysis(image: image)
        #endif
    }

    #if canImport(UIKit)
    private func startAnalysis(image: UIImage) {
        guard let pipeline else { return }
        mode = .analysing
        analysisResult = nil

        analysisTask = Task {
            let retain = context.loadAppSettings().retainAnalysedImages
            do {
                let result = try await pipeline.analyse(image: image, retainImage: retain)
                guard !Task.isCancelled else { return }
                analysisResult = result
                mode = .reviewing
                Haptics.success()
            } catch is CancellationError {
                mode = .idle
            } catch let error as AIServiceError {
                mode = .idle
                Haptics.error()
                if error.isRecoverableBySetup {
                    // No model and no fallback: offer manual entry rather than
                    // pretending analysis is possible (spec section 25).
                    errorMessage = (error.errorDescription ?? "")
                        + " You can add this meal by hand, or configure a remote "
                        + "provider in Settings."
                } else {
                    errorMessage = error.errorDescription
                }
            } catch {
                mode = .idle
                Haptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif

    private func lookUp(barcode: String) async {
        isLookingUpBarcode = true
        defer { isLookingUpBarcode = false }

        let service = BarcodeLookupService(context: context)
        do {
            switch try await service.lookup(barcode: barcode) {
            case .found(let product, let fromCache):
                barcodeOutcome = .found(product, fromCache: fromCache)
                Haptics.success()
            case .notFound(let code):
                barcodeOutcome = .notFound(barcode: code)
                Haptics.warning()
            }
        } catch let error as BarcodeLookupError {
            barcodeOutcome = .failed(error.localizedDescription)
            Haptics.error()
        } catch {
            barcodeOutcome = .failed(error.localizedDescription)
            Haptics.error()
        }
    }

    private func clearCurrentPhoto() {
        if let path = analysisResult?.photoPath {
            ImageStore.delete(relativePath: path)
        }
        #if canImport(UIKit)
        capturedImage = nil
        #endif
        analysisResult = nil
    }

    private func reset() {
        analysisResult = nil
        #if canImport(UIKit)
        capturedImage = nil
        #endif
        mode = .idle
    }
}

/// One of the three scan actions. Large tap target, title plus explanation.
struct ScanActionButton: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 34)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .appCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
    }
}
