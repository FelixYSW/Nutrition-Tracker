import SwiftUI
import AVFoundation
import Vision
#if canImport(UIKit)
import UIKit
#endif
#if canImport(VisionKit)
import VisionKit
#endif

#if canImport(UIKit)

/// Native camera capture for "Take Photo" (spec section 17).
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                // Nothing usable came back; treat it as a cancel rather than
                // silently doing nothing.
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

/// Camera permission state, so the UI can explain rather than fail silently
/// (spec section 34).
enum CameraPermission {
    case authorised, denied, undetermined, restricted

    static func current() -> CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorised
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .undetermined
        @unknown default: .denied
        }
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    var explanation: String? {
        switch self {
        case .authorised, .undetermined:
            nil
        case .denied:
            "Camera access is off for this app. Turn it on in Settings > Privacy "
                + "> Camera to take food photos or scan barcodes."
        case .restricted:
            "Camera access is restricted on this device, so photos and barcode "
                + "scanning are unavailable. You can still add food by hand."
        }
    }
}

#endif

#if canImport(VisionKit)

/// Barcode scanning via VisionKit's `DataScannerViewController`
/// (spec section 27).
///
/// One barcode at a time. The formats requested cover the retail symbologies:
/// EAN-13, EAN-8, UPC-E, plus Code 128 which some local products use.
@available(iOS 17.0, *)
struct BarcodeScannerView: UIViewControllerRepresentable {
    var onBarcode: (String) -> Void
    var onError: (String) -> Void

    @MainActor static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    static let recognisedSymbologies: [VNBarcodeSymbology] = [
        .ean13, .ean8, .upce, .code128
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(onBarcode: onBarcode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: Self.recognisedSymbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        do {
            try controller.startScanning()
        } catch {
            onError("The barcode scanner could not start: \(error.localizedDescription)")
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController,
                                          coordinator: Coordinator) {
        controller.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onBarcode: (String) -> Void
        /// Guards against the delegate firing repeatedly for the same code while
        /// the lookup is already in flight.
        private var hasReported = false

        init(onBarcode: @escaping (String) -> Void) {
            self.onBarcode = onBarcode
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(items: addedItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didTapOn item: RecognizedItem) {
            report(items: [item], scanner: dataScanner)
        }

        private func report(items: [RecognizedItem],
                            scanner: DataScannerViewController) {
            guard !hasReported else { return }
            for item in items {
                if case .barcode(let barcode) = item,
                   let value = barcode.payloadStringValue,
                   !value.isEmpty {
                    hasReported = true
                    scanner.stopScanning()
                    onBarcode(value)
                    return
                }
            }
        }
    }
}

#endif
