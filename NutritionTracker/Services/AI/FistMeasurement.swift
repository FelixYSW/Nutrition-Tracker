import Foundation
import CoreGraphics
import Vision
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Stored value

/// The user's measured fist, used by the assistant as a ruler in food photos.
/// Kept on this device only, like the health notes.
struct HandReference: Codable, Equatable, Sendable {
    /// Across the knuckles of a closed fist, in cm.
    var fistWidthCm: Double
    var measuredAt: Date
    var method: Method

    enum Method: String, Codable, Sendable {
        case scan, manual
    }

    /// A believable adult fist. Anything outside is a misread photo.
    static let plausibleWidthCm: ClosedRange<Double> = 6...13

    /// A typical adult fist is about 8.5 cm across and holds about one cup
    /// (250 ml) when clenched. Volume grows with the cube of size.
    static let averageWidthCm = 8.5
    static let averageVolumeMl = 250.0

    /// Rough volume of this fist, for "about 1.5 fists of rice".
    var approximateVolumeMl: Double {
        (Self.averageVolumeMl * pow(fistWidthCm / Self.averageWidthCm, 3)).rounded()
    }
}

/// UserDefaults is safe to use from any thread, so the store is too.
final class HandReferenceStore: @unchecked Sendable {
    static let shared = HandReferenceStore()

    private let defaults: UserDefaults
    private let key = "handReference.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var reference: HandReference? {
        get {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(HandReference.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

// MARK: - Maths

/// Turns a photo of a hand next to a bank card into a fist width.
///
/// A bank or ID card is the same size everywhere (ISO/IEC 7810 ID-1:
/// 85.60 x 53.98 mm), so it gives the photo a scale: its length in pixels
/// says how many millimetres each pixel covers on the table. That only holds
/// for things lying on the same surface as the card, photographed from
/// straight above, which is what the instructions ask for.
enum FistMeasurement {

    static let cardLongMm = 85.60
    static let cardShortMm = 53.98
    static var cardAspect: Double { cardShortMm / cardLongMm }

    /// Corners of a detected card, in image pixels.
    struct Quad: Equatable {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomRight: CGPoint
        var bottomLeft: CGPoint

        var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

        /// Average length of each pair of opposite sides, longer first.
        var sideLengths: (long: Double, short: Double) {
            let a = (distance(topLeft, topRight) + distance(bottomLeft, bottomRight)) / 2
            let b = (distance(topLeft, bottomLeft) + distance(topRight, bottomRight)) / 2
            return (max(a, b), min(a, b))
        }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }

    /// Millimetres per pixel from the card, using both of its sides. Nil when
    /// the shape is too far from a card's to trust (tilted, or not a card).
    static func millimetresPerPixel(card: Quad) -> Double? {
        let (long, short) = card.sideLengths
        guard long > 0, short > 0 else { return nil }
        let aspect = short / long
        // Up to ~12% off the true ratio: a slightly tilted phone is fine,
        // a steep angle is not.
        guard abs(aspect - cardAspect) / cardAspect < 0.12 else { return nil }
        return (cardLongMm / long + cardShortMm / short) / 2
    }

    /// The fist width in cm for two points (in pixels) on the outer edges of
    /// the knuckles.
    static func widthCm(from a: CGPoint, to b: CGPoint, millimetresPerPixel scale: Double) -> Double {
        // Whole millimetres, shown as cm with one decimal.
        (distance(a, b) * scale).rounded() / 10
    }

    /// Knuckle-centre points (index and little finger) widened to the outer
    /// edges of the hand. The joint centres sit inside the hand's outline,
    /// about a sixth of the span in from each side.
    static func knuckleEdges(index: CGPoint, little: CGPoint) -> (CGPoint, CGPoint) {
        let dx = index.x - little.x
        let dy = index.y - little.y
        let widen: CGFloat = 0.17
        return (CGPoint(x: index.x + dx * widen, y: index.y + dy * widen),
                CGPoint(x: little.x - dx * widen, y: little.y - dy * widen))
    }
}

// MARK: - Detection

#if canImport(UIKit)
/// What Vision found in a measuring photo. Points are in the pixels of
/// `image`, origin top-left.
struct FistScan {
    var image: UIImage
    var card: FistMeasurement.Quad?
    /// Outer knuckle edges, if a hand was found; otherwise nil and the
    /// handles start in the middle for the user to place.
    var knuckles: (CGPoint, CGPoint)?

    var pixelSize: CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
}

enum FistScanner {

    /// Runs card and hand detection on the device. Nothing leaves the phone.
    static func scan(_ original: UIImage) async -> FistScan {
        let image = upright(original)
        guard let cgImage = image.cgImage else { return FistScan(image: image) }
        let size = CGSize(width: cgImage.width, height: cgImage.height)

        return await Task.detached(priority: .userInitiated) {
            let rectangles = VNDetectRectanglesRequest()
            rectangles.minimumAspectRatio = Float(FistMeasurement.cardAspect * 0.85)
            rectangles.maximumAspectRatio = Float(min(1, FistMeasurement.cardAspect * 1.15))
            rectangles.minimumSize = 0.08
            rectangles.quadratureTolerance = 20
            rectangles.maximumObservations = 6

            let hands = VNDetectHumanHandPoseRequest()
            hands.maximumHandCount = 1

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            try? handler.perform([rectangles, hands])

            // Vision's points are normalised with the origin at the bottom left.
            func pixel(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
            }

            let card = (rectangles.results ?? [])
                .map { observation in
                    FistMeasurement.Quad(topLeft: pixel(observation.topLeft),
                                         topRight: pixel(observation.topRight),
                                         bottomRight: pixel(observation.bottomRight),
                                         bottomLeft: pixel(observation.bottomLeft))
                }
                .filter { FistMeasurement.millimetresPerPixel(card: $0) != nil }
                .first

            var knuckles: (CGPoint, CGPoint)?
            if let hand = hands.results?.first,
               let index = try? hand.recognizedPoint(.indexMCP),
               let little = try? hand.recognizedPoint(.littleMCP),
               index.confidence > 0.3, little.confidence > 0.3 {
                knuckles = FistMeasurement.knuckleEdges(index: pixel(index.location),
                                                        little: pixel(little.location))
            }
            return FistScan(image: image, card: card, knuckles: knuckles)
        }.value
    }

    /// Camera photos carry their rotation as metadata; Vision and the overlay
    /// both want the pixels the right way up.
    static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
#endif
