import SwiftUI

/// Settings > Fist size: measure the user's fist once so the assistant can
/// use it as a ruler in food photos.
///
/// Measured from a photo of the hand lying flat next to a bank card (a known
/// size), with two handles the user can nudge onto the knuckle edges; or
/// typed in from a ruler.
struct FistSizeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var reference: HandReference? = HandReferenceStore.shared.reference
    @State private var isShowingCamera = false
    @State private var scan: IdentifiedScan?
    @State private var isScanning = false
    @State private var cameraProblem: String?
    @State private var manualWidth: Double = HandReference.averageWidthCm
    @State private var isEnteringManually = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.pageSpacing) {
                    currentCard
                    howToCard
                    actions
                    if isEnteringManually { manualCard }
                }
                .appPageContent()
            }
            .appPageSurface()
            .navigationTitle("Fist size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                FistCaptureView(onCaptured: { image in
                    isShowingCamera = false
                    analyse(image)
                }, onCancel: { isShowingCamera = false })
            }
            .sheet(item: $scan) { item in
                FistMeasureEditor(scan: item.scan) { width in
                    save(width, method: .scan)
                    scan = nil
                }
            }
            .alert("Camera unavailable", isPresented: Binding(
                get: { cameraProblem != nil }, set: { if !$0 { cameraProblem = nil } })) {
                if CameraPermission.current() == .denied {
                    Button("Open Settings") {
                        cameraProblem = nil
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Not Now", role: .cancel) { cameraProblem = nil }
                } else {
                    Button("OK", role: .cancel) { cameraProblem = nil }
                }
            } message: {
                Text(cameraProblem ?? "")
            }
            .overlay {
                if isScanning {
                    ProgressView("Measuring\u{2026}")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    // MARK: Pieces

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your fist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let reference {
                Text(String(format: "%.1f cm across", reference.fistWidthCm))
                    .scaledHeavyNumber(30, relativeTo: .title)
                Text("About \(Int(reference.approximateVolumeMl)) ml when clenched \u{00B7} "
                     + (reference.method == .scan ? "measured from a photo" : "typed in")
                     + " on \(AppFormatters.dayAndMonth.string(from: reference.measuredAt))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not measured yet")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("Once it's measured, put your fist next to your food in photos and "
                     + "the assistant uses it as a ruler for portion sizes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeading(title: "How to measure")
            step(1, "Put any bank, ID or loyalty card flat on a table. Cards are all "
                    + "the same size, so the app uses it as the scale.")
            step(2, "Make a fist and rest it beside the card, knuckles up.")
            step(3, "Hold the phone flat above them. Fit the card and your fist in "
                    + "their outlines: the photo is taken by itself once both are in "
                    + "place and in focus.")
            step(4, "Check the two dots sit on the outer edges of your knuckles, "
                    + "drag them if not, and save.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.heavy))
                .frame(width: 22, height: 22)
                .background(AppTheme.subtleFill, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                if let explanation = CameraPermission.current().explanation {
                    cameraProblem = explanation
                } else {
                    isShowingCamera = true
                }
            } label: {
                Label(reference == nil ? "Measure with camera" : "Measure again",
                      systemImage: "camera.viewfinder")
            }
            .buttonStyle(.appPrimary)

            Button {
                manualWidth = reference?.fistWidthCm ?? HandReference.averageWidthCm
                withAnimation(.snappy) { isEnteringManually.toggle() }
            } label: {
                Label("Type it in instead", systemImage: "ruler")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.appSecondary)
        }
    }

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measure across your knuckles with a ruler, fist closed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SliderEntryRow(title: "Fist width", value: $manualWidth,
                           range: HandReference.plausibleWidthCm, step: 0.1,
                           unitLabel: "cm", fractionDigits: 1)
            Button("Save") {
                save(manualWidth, method: .manual)
                withAnimation(.snappy) { isEnteringManually = false }
            }
            .buttonStyle(.appPrimary)
        }
        .appCard()
    }

    // MARK: Actions

    private func analyse(_ image: UIImage) {
        isScanning = true
        Task {
            let result = await FistScanner.scan(image)
            isScanning = false
            scan = IdentifiedScan(scan: result)
        }
    }

    private func save(_ width: Double, method: HandReference.Method) {
        let value = HandReference(fistWidthCm: (width * 10).rounded() / 10,
                                  measuredAt: .now, method: method)
        HandReferenceStore.shared.reference = value
        reference = value
        Haptics.success()
    }
}

private struct IdentifiedScan: Identifiable {
    let id = UUID()
    let scan: FistScan
}

// MARK: - Placing the handles

/// The measuring photo with the card outlined and two draggable dots on the
/// knuckle edges. The width updates live as the dots move.
struct FistMeasureEditor: View {
    @Environment(\.dismiss) private var dismiss

    let scan: FistScan
    let onSave: (Double) -> Void

    /// Handle positions in image pixels.
    @State private var a: CGPoint = .zero
    @State private var b: CGPoint = .zero

    private var scale: Double? {
        scan.card.flatMap(FistMeasurement.millimetresPerPixel(card:))
    }

    private var width: Double? {
        scale.map { FistMeasurement.widthCm(from: a, to: b, millimetresPerPixel: $0) }
    }

    private var isPlausible: Bool {
        width.map { HandReference.plausibleWidthCm.contains($0) } ?? false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geometry in
                    let frame = fittedFrame(in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        // Handles are dragged in this space: the photo area.
                        Image(uiImage: scan.image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityLabel("Your measuring photo")

                        if let card = scan.card {
                            Path { path in
                                let points = card.corners.map { toView($0, frame) }
                                path.addLines(points)
                                path.closeSubpath()
                            }
                            .stroke(AppTheme.within, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                            .accessibilityHidden(true)
                        }

                        Path { path in
                            path.move(to: toView(a, frame))
                            path.addLine(to: toView(b, frame))
                        }
                        .stroke(Color.white, lineWidth: 2)
                        .shadow(radius: 2)
                        .accessibilityHidden(true)

                        handle($a, frame: frame, label: "Index-finger knuckle edge")
                        handle($b, frame: frame, label: "Little-finger knuckle edge")
                    }
                    .coordinateSpace(name: Self.photoSpace)
                }
                .frame(maxHeight: .infinity)

                readout
            }
            .padding()
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Check the dots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retake") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let width { onSave(width) }
                        dismiss()
                    }
                    .disabled(!isPlausible)
                }
            }
            .onAppear(perform: placeHandles)
        }
    }

    @ViewBuilder
    private var readout: some View {
        if scale == nil {
            Label("No card found. Retake with the whole card flat beside your hand, "
                  + "photographed from straight above.", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(AppTheme.stateTextColor(for: .over))
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCard()
        } else if let width {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.1f cm", width))
                    .scaledHeavyNumber(30, relativeTo: .title)
                    .monospacedDigit()
                Text(isPlausible
                     ? (scan.knuckles == nil
                        ? "Your hand wasn't found automatically: drag the dots to the outer "
                            + "edges of your knuckles."
                        : "Drag the dots if they aren't on the outer edges of your knuckles.")
                     : "That's outside the usual 6 to 13 cm. Check the dots, or retake the photo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard()
        }
    }

    private func handle(_ point: Binding<CGPoint>, frame: CGRect, label: String) -> some View {
        Circle()
            .fill(AppTheme.accentFill)
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .frame(width: 22, height: 22)
            // A 44 pt area to grab, around a small dot that doesn't hide the knuckle.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .position(toView(point.wrappedValue, frame))
            .gesture(DragGesture(coordinateSpace: .named(Self.photoSpace)).onChanged { value in
                point.wrappedValue = toImage(value.location, frame)
            })
            .accessibilityLabel(label)
            .accessibilityHint("Drag to the outer edge of the knuckle")
    }

    // MARK: Coordinates

    private static let photoSpace = "fistPhoto"

    private func fittedFrame(in size: CGSize) -> CGRect {
        let image = scan.pixelSize
        guard image.width > 0, image.height > 0 else { return .zero }
        let ratio = min(size.width / image.width, size.height / image.height)
        let fitted = CGSize(width: image.width * ratio, height: image.height * ratio)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func toView(_ p: CGPoint, _ frame: CGRect) -> CGPoint {
        let image = scan.pixelSize
        guard image.width > 0 else { return .zero }
        return CGPoint(x: frame.minX + p.x / image.width * frame.width,
                       y: frame.minY + p.y / image.height * frame.height)
    }

    private func toImage(_ p: CGPoint, _ frame: CGRect) -> CGPoint {
        let image = scan.pixelSize
        guard frame.width > 0 else { return .zero }
        let x = min(max(p.x, frame.minX), frame.maxX)
        let y = min(max(p.y, frame.minY), frame.maxY)
        return CGPoint(x: (x - frame.minX) / frame.width * image.width,
                       y: (y - frame.minY) / frame.height * image.height)
    }

    /// From the detected knuckles, or a guess in the middle of the photo,
    /// about an average fist apart, for the user to drag into place.
    private func placeHandles() {
        if let knuckles = scan.knuckles {
            a = knuckles.0
            b = knuckles.1
            return
        }
        let size = scan.pixelSize
        let span = scale.map { HandReference.averageWidthCm * 10 / $0 } ?? Double(size.width) * 0.25
        a = CGPoint(x: size.width / 2 - span / 2, y: size.height / 2)
        b = CGPoint(x: size.width / 2 + span / 2, y: size.height / 2)
    }
}
