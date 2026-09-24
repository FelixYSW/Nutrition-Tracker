import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import VisionKit

struct ScanView: View {
    @Environment(\.modelContext) private var context
    @Environment(DraftStore.self) private var store
    @Query private var cache: [BarcodeProductCache]
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var showCamera = false
    @State private var showBarcode = false
    @State private var showReplacement = false
    @State private var pendingImage: Data?
    @State private var stage: String?
    @State private var message: String?
    @State private var missingBarcode: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("QUICK CAPTURE").font(.caption.bold()).tracking(1.4).foregroundStyle(AppTheme.accent)
                        Text("Scan your food").font(.largeTitle.bold())
                        Text("Use one photo or a product barcode to start a food entry.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.bottom, 6)

                    if let data = imageData, let image = UIImage(data: data) {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 220)
                                .clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                            Text("Current photo").font(.subheadline.bold())
                            Text("Portions from a single photo are approximate. Review every result.")
                                .font(.caption).foregroundStyle(.secondary)
                            if stage == nil {
                                Button("Analyse Photo") { Task { await analyze() } }
                                    .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 48)
                                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                            }
                        }.appCard()
                    }

                    AppSectionHeading(title: "Choose a method")
                    Button { openCamera() } label: {
                        ScanActionLabel(icon: "camera.fill", title: "Take Photo", subtitle: "Capture a meal with your camera")
                    }.buttonStyle(.plain)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        ScanActionLabel(icon: "photo.on.rectangle.angled", title: "Choose Photo", subtitle: "Select one image from your library")
                    }.buttonStyle(.plain)
                    Button { openBarcode() } label: {
                        ScanActionLabel(icon: "barcode.viewfinder", title: "Scan Barcode", subtitle: "Find packaged food nutrition")
                    }.buttonStyle(.plain)

                    if let stage { LoadingAnalysisView(stage: stage).frame(maxWidth: .infinity).appCard() }
                    if let code = missingBarcode {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Product Not Found").font(.headline)
                            Text("Barcode \(code) is not in the food database.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Enter Product Manually") {
                                var draft = FoodDraft(); draft.barcode = code; draft.source = .barcode
                                store.load(draft); missingBarcode = nil
                            }.buttonStyle(.borderedProminent).tint(AppTheme.accent)
                            Button("Scan Another Barcode") { missingBarcode = nil; openBarcode() }
                        }.frame(maxWidth: .infinity, alignment: .leading).appCard()
                    }
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
            }
                .background(AppTheme.background.ignoresSafeArea())
                .navigationTitle("Scan")
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: photoItem) { _, item in
                    Task { if let data = try? await item?.loadTransferable(type: Data.self) { receive(data) } }
                }
                .sheet(isPresented: $showCamera) { CameraPicker { data in showCamera = false; if let data { receive(data) } } }
                .sheet(isPresented: $showBarcode) {
                    BarcodeScanner { code in showBarcode = false; Task { await lookup(code) } }
                }
                .confirmationDialog("Replace current photo?", isPresented: $showReplacement) {
                    Button("Replace Photo") { imageData = pendingImage; pendingImage = nil }
                    Button("Keep Current Photo", role: .cancel) { pendingImage = nil }
                }
                .alert("Scan", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("OK") { message = nil }
                } message: { Text(message ?? "") }
        }
    }
    private func receive(_ data: Data) {
        guard (try? ImagePreparation.prepare(data)) != nil else { message = "Invalid image"; return }
        if imageData != nil { pendingImage = data; showReplacement = true }
        else { imageData = data }
    }
    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { message = "Camera unavailable"; return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied { message = "Enable camera access in Settings."; return }
        showCamera = true
    }
    private func openBarcode() {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            message = "Barcode scanner unavailable on this device or camera permission is off."; return
        }
        showBarcode = true
    }
    private func analyze() async {
        guard let data = imageData else { return }
        stage = "Image prepared"
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await PhotoAnalyzer().analyze(data) { newStage in stage = newStage }
            }.value
            guard !result.detections.isEmpty else { message = "No foods recognized. Enter food manually."; stage = nil; return }
            let original = try? JSONEncoder().encode(result)
            store.aiOriginal = original
            store.pendingImage = data
            store.load(PhotoAnalyzer.draft(from: result))
        } catch { message = error.localizedDescription }
        stage = nil
    }
    private func lookup(_ code: String) async {
        stage = "Looking up product"
        defer { stage = nil }
        do {
            let product: BarcodeProductCache?
            if let cached = cache.first(where: { $0.barcode == code }) { product = cached }
            else { product = try await OpenFoodFactsService().lookup(code) }
            guard let product else { missingBarcode = code; return }
            if !cache.contains(where: { $0.barcode == code }) { context.insert(product); try? context.save() }
            var draft = FoodDraft()
            draft.name = product.name; draft.barcode = code; draft.source = .barcode
            draft.quantity = product.servingSize; draft.servingSize = product.servingSize
            draft.unit = ServingUnit(rawValue: product.unitRaw) ?? .gram
            draft.nutrition = product.nutrition
            store.load(draft)
        } catch { message = "Product lookup failed: \(error.localizedDescription)" }
    }
}

private struct ScanActionLabel: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(AppTheme.accent)
                .frame(width: 48, height: 48)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }.frame(minHeight: 58).appCard()
    }
}
