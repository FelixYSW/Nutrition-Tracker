import SwiftUI
import AVFoundation
import Vision
import UIKit

/// Live camera for measuring the fist.
///
/// Everything - the camera image, the dimmed surround, the outlines and the
/// detection - is laid out in one full-screen space, so what the app sees
/// lines up with what's drawn. Three checks show live at the top (card in its
/// outline, fist in its outline, held still); when all three hold for about
/// half a second the photo is taken, with a ring round the shutter filling
/// up as it gets there. The shutter also works by hand at any time.
struct FistCaptureView: View {
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = FistCameraController()
    @State private var cardOK = false
    @State private var fistOK = false
    @State private var steadyFrames = 0
    @State private var lastCorners: [CGPoint]?
    @State private var isCapturing = false
    /// When the card first sat in place without a fist being found, to offer
    /// the shutter instead of waiting forever.
    @State private var cardOnlySince: Date?
    /// The card as last seen, drawn so the user sees what the app sees.
    @State private var seenCard: [CGPoint]?

    /// Frames in a row (about 0.15 s apart) that must be in place and still.
    static let framesToCapture = 4

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            GeometryReader { geometry in
                screen(size: geometry.size, insets: insets)
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .statusBarHidden()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.capturedImage) { _, image in
            if let image { onCaptured(image) }
        }
    }

    private func screen(size: CGSize, insets: EdgeInsets) -> some View {
        let cardGuide = Self.cardGuide(in: size)
        let fistGuide = Self.fistGuide(in: size)
        return ZStack {
            CameraPreview(session: camera.session)

            // Dim everything but the two outlines, cut out in this same space.
            Color.black.opacity(0.5)
                .mask {
                    Rectangle()
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .frame(width: cardGuide.width, height: cardGuide.height)
                                .position(x: cardGuide.midX, y: cardGuide.midY)
                                .blendMode(.destinationOut)
                            FistOutline()
                                .frame(width: fistGuide.width, height: fistGuide.height)
                                .position(x: fistGuide.midX, y: fistGuide.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .allowsHitTesting(false)

            GuideCorners(cornerRadius: 14)
                .stroke(cardOK ? AppTheme.within : .white,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: cardGuide.width, height: cardGuide.height)
                .position(x: cardGuide.midX, y: cardGuide.midY)
                .allowsHitTesting(false)
            FistOutline()
                .stroke(fistOK ? AppTheme.within : .white,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round,
                                           dash: fistOK ? [] : [9, 6]))
                .frame(width: fistGuide.width, height: fistGuide.height)
                .position(x: fistGuide.midX, y: fistGuide.midY)
                .allowsHitTesting(false)

            // The card as the app sees it.
            if let seenCard {
                Path { path in
                    path.addLines(seenCard)
                    path.closeSubpath()
                }
                .stroke(AppTheme.within.opacity(0.9), lineWidth: 2)
                .allowsHitTesting(false)
            }

            guideLabel("Card", in: cardGuide, done: cardOK)
            guideLabel("Fist", in: fistGuide.offsetBy(dx: 0, dy: -30), done: fistOK)

            VStack(spacing: 12) {
                HStack {
                    Button("Cancel", action: onCancel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                    Spacer()
                }
                checklist
                Spacer()
                Text(camera.problem ?? hint)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .accessibilityAddTraits(.updatesFrequently)
                shutter
            }
            .padding(.horizontal, 16)
            .padding(.top, insets.top)
            .padding(.bottom, max(insets.bottom, 16))
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: camera.detection) { _, detection in
            update(with: detection, viewSize: size, cardGuide: cardGuide, fistGuide: fistGuide)
        }
    }

    // MARK: Pieces

    private var checklist: some View {
        HStack(spacing: 8) {
            check("Card", done: cardOK)
            check("Fist", done: fistOK)
            check("Still", done: cardOK && fistOK && steadyFrames > 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func check(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(done ? AppTheme.within.opacity(0.9) : Color.black.opacity(0.6),
                        in: Capsule())
            .accessibilityLabel("\(title) \(done ? "done" : "not yet")")
    }

    private func guideLabel(_ title: String, in rect: CGRect, done: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .position(x: rect.minX + 34, y: rect.minY + 16)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var shutter: some View {
        let progress = Double(steadyFrames) / Double(Self.framesToCapture)
        return Button {
            capture()
        } label: {
            ZStack {
                Circle().fill(.white.opacity(0.9)).frame(width: 62, height: 62)
                Circle().stroke(.white.opacity(0.5), lineWidth: 5).frame(width: 76, height: 76)
                // Fills as the photo is about to take itself.
                Circle()
                    .trim(from: 0, to: min(1, progress))
                    .stroke(AppTheme.within, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 76, height: 76)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isCapturing)
        .accessibilityLabel("Take photo now")
    }

    private var hint: String {
        if isCapturing { return "Got it" }
        if !cardOK { return "Move the card into the top frame" }
        if !fistOK {
            if let since = cardOnlySince, Date.now.timeIntervalSince(since) > 3 {
                return "Can't spot your fist. Tap the button to take it yourself"
            }
            return "Rest your fist, knuckles up, in the lower frame"
        }
        return "Hold still\u{2026}"
    }

    // MARK: Layout

    /// A card lying across the upper part of the screen. Bigger is easier:
    /// the phone is held closer and the card's edges are clearer.
    static func cardGuide(in size: CGSize) -> CGRect {
        let width = size.width * 0.72
        let height = width * FistMeasurement.cardAspect
        return CGRect(x: (size.width - width) / 2, y: size.height * 0.30 - height / 2,
                      width: width, height: height)
    }

    /// A fist seen from above, just below the card.
    static func fistGuide(in size: CGSize) -> CGRect {
        let card = cardGuide(in: size)
        let width = size.width * 0.46
        let height = width * 1.2
        return CGRect(x: (size.width - width) / 2, y: card.maxY + 28,
                      width: width, height: height)
    }

    // MARK: Auto-capture

    private func update(with detection: FistCameraController.Detection, viewSize: CGSize,
                        cardGuide: CGRect, fistGuide: CGRect) {
        guard !isCapturing else { return }
        let toView = { (p: CGPoint) in
            Self.viewPoint(p, imageSize: detection.imageSize, viewSize: viewSize)
        }
        let card = detection.cardCorners?.map(toView)
        seenCard = card
        cardOK = card.map { Self.cardFits($0, in: cardGuide) } ?? false
        let knuckles = detection.knuckleMidpoint.map(toView)
        fistOK = knuckles.map {
            fistGuide.insetBy(dx: -fistGuide.width * 0.25, dy: -fistGuide.height * 0.25).contains($0)
        } ?? false

        if cardOK, !fistOK {
            if cardOnlySince == nil { cardOnlySince = .now }
        } else {
            cardOnlySince = nil
        }

        guard cardOK, fistOK, let card else {
            steadyFrames = 0
            lastCorners = nil
            return
        }
        // Still: the card hasn't moved more than ~2% of the screen width.
        let moved = zip(card, lastCorners ?? card)
            .map { FistMeasurement.distance($0, $1) }.max() ?? 0
        lastCorners = card
        guard detection.isFocused, moved < Double(viewSize.width) * 0.02 else {
            steadyFrames = 0
            return
        }
        steadyFrames += 1
        if steadyFrames >= Self.framesToCapture { capture() }
    }

    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        Haptics.success()
        camera.capturePhoto()
    }

    /// The card counts as in place when its middle is in (or near) the frame
    /// and it's roughly the frame's size - not a small card far away, which
    /// would give a poor scale.
    static func cardFits(_ corners: [CGPoint], in guide: CGRect) -> Bool {
        guard corners.count == 4 else { return false }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else { return false }
        let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let near = guide.insetBy(dx: -guide.width * 0.25, dy: -guide.height * 0.35)
        let width = max(maxX - minX, maxY - minY)
        return near.contains(centre) && width >= guide.width * 0.5 && width <= guide.width * 1.35
    }

    /// A point in the upright camera image (0...1, origin top left) to the
    /// screen, for a preview that fills the whole screen and crops the overflow.
    static func viewPoint(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offsetX = (viewSize.width - imageSize.width * scale) / 2
        let offsetY = (viewSize.height - imageSize.height * scale) / 2
        return CGPoint(x: p.x * imageSize.width * scale + offsetX,
                       y: p.y * imageSize.height * scale + offsetY)
    }
}

/// A closed fist seen from above, knuckles up, as it rests beside the card:
/// four knuckles along the top, the thumb folded along the left side, and
/// the wrist narrowing at the bottom. Drawn to fill its frame.
struct FistOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        // Up the left side to the first knuckle.
        path.move(to: p(0.10, 0.28))
        // Four knuckles, index to little finger, each a low rounded bump.
        let knuckles: [(start: CGFloat, end: CGFloat, top: CGFloat)] =
            [(0.10, 0.31, 0.06), (0.31, 0.52, 0.03), (0.52, 0.72, 0.05), (0.72, 0.90, 0.10)]
        for knuckle in knuckles {
            let mid = (knuckle.start + knuckle.end) / 2
            path.addCurve(to: p(knuckle.end, knuckle.top + 0.07),
                          control1: p(knuckle.start + 0.02, knuckle.top - 0.02),
                          control2: p(mid + 0.06, knuckle.top - 0.03))
        }
        // Down the little-finger side, which bulges a little, into the wrist.
        path.addCurve(to: p(0.82, 0.76), control1: p(0.99, 0.30), control2: p(0.98, 0.62))
        path.addCurve(to: p(0.76, 1.0), control1: p(0.77, 0.81), control2: p(0.76, 0.88))
        // Across the wrist and back up into the thumb side.
        path.addLine(to: p(0.34, 1.0))
        path.addCurve(to: p(0.28, 0.82), control1: p(0.34, 0.90), control2: p(0.32, 0.85))
        // The thumb, folded against the side of the fist.
        path.addCurve(to: p(0.03, 0.52), control1: p(0.12, 0.77), control2: p(0.02, 0.67))
        path.addCurve(to: p(0.10, 0.28), control1: p(0.03, 0.41), control2: p(0.05, 0.32))
        path.closeSubpath()
        // The crease where the thumb meets the fingers.
        path.move(to: p(0.12, 0.40))
        path.addCurve(to: p(0.34, 0.66), control1: p(0.20, 0.46), control2: p(0.30, 0.56))
        return path
    }
}

/// Just the four corners of a rounded rectangle, like a camera viewfinder:
/// lighter than a full dashed box, and the frame stays clear to look through.
struct GuideCorners: Shape {
    var cornerRadius: CGFloat
    var length: CGFloat = 30

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, length)
        let l = length
        // Top left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // Top right
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // Bottom right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // Bottom left
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return path
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
        /// Middle of the knuckles (or the wrist) that were seen, same space.
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
    private let stillOutput = AVCapturePhotoOutput()
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
            stillOutput.capturePhoto(with: settings, delegate: self)
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
        if session.canAddOutput(stillOutput) { session.addOutput(stillOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // The photo comes out upright for a phone held in portrait.
        if let connection = stillOutput.connection(with: .video),
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
        // A closed fist hides most of the hand from the detector, so any
        // knuckle or the wrist is enough to say where the fist is.
        if let hand = hands.results?.first {
            let joints: [VNHumanHandPoseObservation.JointName] =
                [.indexMCP, .middleMCP, .ringMCP, .littleMCP, .wrist]
            let seen = joints.compactMap { try? hand.recognizedPoint($0) }
                .filter { $0.confidence > 0.25 }
                .map { topLeft($0.location) }
            if !seen.isEmpty {
                result.knuckleMidpoint = CGPoint(
                    x: seen.map(\.x).reduce(0, +) / CGFloat(seen.count),
                    y: seen.map(\.y).reduce(0, +) / CGFloat(seen.count))
            }
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
