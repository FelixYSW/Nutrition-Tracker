import CoreLocation
import Foundation

/// Where the user is right now, for "somewhere to eat nearby".
struct CurrentPlace: Equatable, Sendable {
    /// Neighbourhood and city when they could be looked up, e.g. "Bangsar, Kuala Lumpur".
    var name: String?
    var latitude: Double
    var longitude: Double

    /// For a search: the area name with the coordinates, so results stay
    /// near the user even when the name is broad.
    var searchDescription: String {
        let coordinates = String(format: "%.4f, %.4f", latitude, longitude)
        return name.map { "\($0) (coordinates \(coordinates))" } ?? "coordinates \(coordinates)"
    }
}

enum CurrentLocationError: LocalizedError, Equatable {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            "Location access is off for this app, so the current location isn't available."
        case .unavailable:
            "The current location couldn't be found just now."
        }
    }
}

protocol CurrentLocating: Sendable {
    func currentPlace() async throws -> CurrentPlace
}

/// One-off location lookup. Asks for "while using the app" permission the
/// first time it is needed - only when the user asks for food nearby without
/// naming a place - and never tracks location in the background.
@MainActor
final class CurrentLocationProvider: NSObject, CLLocationManagerDelegate, CurrentLocating {

    /// Neighbourhood accuracy is plenty for finding places to eat, and is fast.
    private let manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return manager
    }()
    private var continuation: CheckedContinuation<(Double, Double), Error>?

    /// Gives up after this long rather than leaving the chat on "Thinking…".
    static let timeout: UInt64 = 10_000_000_000

    override init() {
        super.init()
        manager.delegate = self
    }

    func currentPlace() async throws -> CurrentPlace {
        let (latitude, longitude) = try await coordinates()
        return CurrentPlace(name: await Self.areaName(latitude: latitude, longitude: longitude),
                            latitude: latitude, longitude: longitude)
    }

    private func coordinates() async throws -> (Double, Double) {
        switch manager.authorizationStatus {
        case .denied, .restricted: throw CurrentLocationError.denied
        default: break
        }
        // Only one lookup at a time; a newer request replaces an older one.
        continuation?.resume(throwing: CurrentLocationError.unavailable)
        continuation = nil

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeout)
            self?.finish(.failure(CurrentLocationError.unavailable))
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()   // the location follows on approval
            } else {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<(Double, Double), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard continuation != nil else { return }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: finish(.failure(CurrentLocationError.denied))
        default: break
        }
    }

    /// "Bangsar, Kuala Lumpur" - the neighbourhood and city, without repeats.
    private static func areaName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        var parts: [String] = []
        for part in [placemark.name, placemark.subLocality, placemark.locality,
                     placemark.administrativeArea].compactMap({ $0 }) where !parts.contains(part) {
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let value = (coordinate.latitude, coordinate.longitude)
        Task { @MainActor in self.finish(.success(value)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            self.finish(.failure(denied ? CurrentLocationError.denied : CurrentLocationError.unavailable))
        }
    }
}
