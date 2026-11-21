import SwiftUI
import AVFoundation
import Vision
import UIKit

/// Live camera for measuring the fist: an outline for the card and one for
/// the fist. Each frame is checked on the device; once the card fills its
/// outline, the knuckles are in theirs, focus has settled and nothing moves
/// for about half a second, the photo is taken by itself. A shutter button
/// stays as a fallback.
struct FistCaptureView: View {
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = FistCameraController()
    @State private var steadyFrames = 0
    @State private var lastCorners: [CGPoint]?
    @State private var guide = GuideState.lookingForCard

    /// Frames in a row (about 0.15 s apart) that must be aligned and still.
    private static let framesToCapture = 4

    enum GuideState: Equatable {
        case lookingForCard, lookingForFist, holdStill, capturing

        var message: String {
            switch self {
            case .lookingForCard: "Fit the card inside the top outline"
            case .lookingForFist: "Put your fist, knuckles up, in the lower outline"
            case .holdStill: "Hold still\u{2026}"
            case .capturing: "Got it"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let cardGuide = Self.cardGuide(in: size)
            let fistGuide = Self.fistGuide(in: size)
            let cardMatched = guide != .lookingForCard
            let fistMatched = guide == .holdStill || guide == .capturing

            ZStack {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                // Dim everything outside the two outlines.
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .mask {
                        Rectangle()
                            .overlay {
                                RoundedRectangle(cornerRadius: 12).frame(width: cardGuide.width, height: cardGuide.height)
                                    .position(x: cardGuide.midX, y: cardGuide.midY)
                                    .blendMode(.destinationOut)
                                RoundedRectangle(cornerRadius: 40).frame(width: fistGuide.width, height: fistGuide.height)
                                    .position(x: fistGuide.midX, y: fistGuide.midY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                outline(cardGuide, cornerRadius: 12, label: "Card", matched: cardMatched)
                outline(fistGuide, cornerRadius: 40, label: "Fist", matched: fistMatched)

                VStack {
                    HStack {
                        Button("Cancel", action: onCancel)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 44, minHeight: 44)
                        Spacer()
                    }
                    .padding(.horizontal)

                    Spacer()

                    Text(camera.problem ?? guide.message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .accessibilityAddTraits(.updatesFrequently)

                    Text("Phone flat above the table, card and fist side by side.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)

                    Button {
                        capture()
                    } label: {
                        Circle()
                            .strokeBorder(.white, lineWidth: 4)
                            .background(Circle().fill(.white.opacity(0.25)))
                            .frame(width: 72, height: 72)
                    }
                    .accessibilityLabel("Take photo now")
                    .padding(.vertical, 20)
                    .disabled(guide == .capturing)
                }
            }
            .onChange(of: camera.detection) { _, detection in
                update(with: detection, viewSize: size, cardGuide: cardGuide, fistGuide: fistGuide)
            }
        }
        .background(Color.black)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.capturedImage) { _, image in
            if let image { onCaptured(image) }
        }
    }

    private func outline(_ rect: CGRect, cornerRadius: CGFloat, label: String, matched: Bool) -> some View {
        let color: Color = matched ? AppTheme.within : .white
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 3, dash: matched ? [] : [8, 6]))
            // White on near-black reads over any camera image; the tick
            // says "in place" without relying on the green.
            Label(label, systemImage: matched ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7), in: Capsule())
                .offset(y: -12)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("\(label) outline, \(matched ? "in place" : "not yet in place")")
    }

    // MARK: Guides

    /// A card lying across the screen in the upper part.
    static func cardGuide(in size: CGSize) -> CGRect {
        let width = size.width * 0.6
        let height = width * FistMeasurement.cardAspect
        return CGRect(x: (size.width - width) / 2, y: size.height * 0.24 - height / 2,
                      width: width, height: height)
    }

    /// Room for a fist seen from above, below the card.
    static func fistGuide(in size: CGSize) -> CGRect {
        let width = size.width * 0.5
        let height = width * 0.9
        return CGRect(x: (size.width - width) / 2, y: size.height * 0.5 - height / 2,
                      width: width, height: height)
    }

    // MARK: Auto-capture

    private func update(with detection: FistCameraController.Detection, viewSize: CGSize,
                        cardGuide: CGRect, fistGuide: CGRect) {
        guard guide != .capturing else { return }
        let toView = { (p: CGPoint) in
            Self.viewPoint(p, imageSize: detection.imageSize, viewSize: viewSize)
        }

        guard let card = detection.cardCorners?.map(toView),
              Self.cardFits(card, in: cardGuide) else {
            reset(to: .lookingForCard)
            return
        }
        guard let knuckles = detection.knuckleMidpoint.map(toView),
              fistGuide.insetBy(dx: -fistGuide.width * 0.1, dy: -fistGuide.height * 0.1)
                .contains(knuckles) else {
            reset(to: .lookingForFist)
            return
        }

        // Still: the card hasn't moved more than ~1.5% of the screen width.
        let moved = zip(card, lastCorners ?? card)
            .map { FistMeasurement.distance($0, $1) }.max() ?? 0
        lastCorners = card
        guard detection.isFocused, moved < Double(viewSize.width) * 0.015 else {
            steadyFrames = 0
            guide = .holdStill
            return
        }
        guide = .holdStill
        steadyFrames += 1
        if steadyFrames >= Self.framesToCapture { capture() }
    }

    private func reset(to state: GuideState) {
        guide = state
        steadyFrames = 0
        lastCorners = nil
    }

    private func capture() {
        guard guide != .capturing else { return }
        guide = .capturing
        Haptics.success()
        camera.capturePhoto()
    }

    /// Every corner near the outline, and the card about as big as it: not
    /// a small card somewhere inside it.
    static func cardFits(_ corners: [CGPoint], in guide: CGRect) -> Bool {
        let slack = guide.insetBy(dx: -guide.width * 0.15, dy: -guide.height * 0.25)
        guard corners.count == 4, corners.allSatisfy(slack.contains) else { return false }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        return width >= guide.width * 0.7
    }

    /// A point in the upright camera image (0...1, origin top left) to the
    /// screen, for a preview that fills the screen and crops the overflow.
    static func viewPoint(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offsetX = (viewSize.width - imageSize.width * scale) / 2
        let offsetY = (viewSize.height - imageSize.height * scale) / 2
        return CGPoint(x: p.x * imageSize.width * scale + offsetX,
                       y: p.y * imageSize.height * scale + offsetY)
    }
}

// MARK: - Camera

/// Runs the back camera, checks frames with Vision and takes the full-size
/// photo. Nothing is recorded or sent anywhere.
final class FistCameraController: NSObject, ObservableObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    struct Detection: Equatable {
        /// Card corners in the upright frame, 0...1 with the origin top left.
        var cardCorners: [CGPoint]?
        /// Between the index and little-finger knuckles, same space.
        var knuckleMidpoint: CGPoint?
        /// The upright frame's size in pixels.
        var imageSize: CGSize = .zero
        var isFocused = false
    }

    let session = AVCaptureSession()
    @Published private(set) var detection = Detection()
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var problem: String?

    private let queue = DispatchQueue(label: "fist.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var lastAnalysis = Date.distantPast
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                if granted { run() } else { publishProblem("Camera access is off. Turn it on in Settings.") }
            }
        default:
            publishProblem("Camera access is off. Turn it on in Settings.")
        }
    }

    private func run() {
        queue.async { [self] in
            if !isConfigured { configure() }
            if isConfigured, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capturePhoto() {
        queue.async { [self] in
            guard session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            publishProblem("The camera isn't available on this device.")
            return
        }
        self.device = device
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // The photo comes out upright for a phone held in portrait.
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        session.commitConfiguration()

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
        isConfigured = true
    }

    private func publishProblem(_ text: String) {
        DispatchQueue.main.async { self.problem = text }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // About 6 checks a second is plenty and keeps the phone cool.
        guard Date.now.timeIntervalSince(lastAnalysis) > 0.15,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = .now

        // The sensor's frames are landscape; .right turns them upright for
        // a phone held in portrait, so Vision's points match the screen.
        let upright = CGSize(width: CVPixelBufferGetHeight(buffer),
                             height: CVPixelBufferGetWidth(buffer))

        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = Float(FistMeasurement.cardAspect * 0.85)
        rectangles.maximumAspectRatio = Float(min(1, FistMeasurement.cardAspect * 1.15))
        rectangles.minimumSize = 0.15
        rectangles.quadratureTolerance = 15
        rectangles.maximumObservations = 4
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
        try? handler.perform([rectangles, hands])

        func topLeft(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

        var result = Detection(imageSize: upright)
        result.cardCorners = (rectangles.results ?? []).lazy
            .map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft].map(topLeft) }
            .first { corners in
                let pixels = corners.map { CGPoint(x: $0.x * upright.width, y: $0.y * upright.height) }
                let quad = FistMeasurement.Quad(topLeft: pixels[0], topRight: pixels[1],
                                                bottomRight: pixels[2], bottomLeft: pixels[3])
                return FistMeasurement.millimetresPerPixel(card: quad) != nil
            }
        if let hand = hands.results?.first,
           let index = try? hand.recognizedPoint(.indexMCP),
           let little = try? hand.recognizedPoint(.littleMCP),
           index.confidence > 0.3, little.confidence > 0.3 {
            let a = topLeft(index.location), b = topLeft(little.location)
            result.knuckleMidpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        if let device {
            result.isFocused = !device.isAdjustingFocus && !device.isAdjustingExposure
        }
        DispatchQueue.main.async { self.detection = result }
    }

    // MARK: Photo

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            publishProblem("The photo couldn't be taken. Try again.")
            return
        }
        stop()
        DispatchQueue.main.async { self.capturedImage = image }
    }
}

/// The camera feed, filling its frame.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // The connection exists only once the session has its input.
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}
