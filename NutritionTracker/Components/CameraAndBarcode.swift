import SwiftUI
import AVFoundation
import Vision
#if canImport(UIKit)
import UIKit
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
            "Camera access is off for this app. Turn it on in Settings to take "
                + "food photos, or pick a photo from your library."
        case .restricted:
            "Camera access is restricted on this device, so photos are "
                + "unavailable. You can still add food by hand."
        }
    }
}

#endif
