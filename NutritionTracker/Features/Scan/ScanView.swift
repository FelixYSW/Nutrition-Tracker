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
            VStack(spacing: 20) {
                if let data = imageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Button { openCamera() } label: { Label("Take Photo", systemImage: "camera") }
                    .buttonStyle(.borderedProminent)
                PhotosPicker(selection: $photoItem, maxSelectionCount: 1, matching: .images) {
                    Label("Choose Photo", systemImage: "photo")
                }.buttonStyle(.bordered)
                Button { openBarcode() } label: { Label("Scan Barcode", systemImage: "barcode.viewfinder") }
                    .buttonStyle(.bordered)
                if let stage { LoadingAnalysisView(stage: stage) }
                if imageData != nil && stage == nil {
                    Button("Analyse Photo") { Task { await analyze() } }.buttonStyle(.borderedProminent)
                }
                if let code = missingBarcode {
                    Text("Product Not Found").font(.headline)
                    Button("Enter Product Manually") {
                        var draft = FoodDraft(); draft.barcode = code; draft.source = .barcode
                        store.load(draft); missingBarcode = nil
                    }
                    Button("Scan Another Barcode") { missingBarcode = nil; openBarcode() }
                }
                Spacer()
            }.padding()
                .navigationTitle("Scan")
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
