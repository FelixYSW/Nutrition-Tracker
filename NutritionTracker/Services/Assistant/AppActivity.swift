import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Whether the app is in the foreground, so a network request cut off by iOS
/// suspending the app can be told apart from a real failure, and resent once
/// the user is back.
@MainActor
final class AppActivity {
    static let shared = AppActivity()

    /// When the app last went into the background.
    private(set) var lastBackgrounded: Date?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppActivity.shared.lastBackgrounded = .now }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppActivity.shared.resumeWaiters() }
        }
        #endif
    }

    var isActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    /// True if the app went into the background at any point since `date`.
    func wasBackgrounded(since date: Date) -> Bool {
        guard let lastBackgrounded else { return false }
        return lastBackgrounded >= date
    }

    /// Returns once the app is in the foreground again (at once if it is).
    func waitUntilActive() async {
        guard !isActive else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    // MARK: Background time

    /// Asks iOS to keep the app running while a request finishes after the
    /// user switches away (usually up to about 30 seconds). Returns a token
    /// for `endBackgroundWork`.
    func beginBackgroundWork(named name: String) -> Int {
        #if canImport(UIKit)
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: give the time back; the request is retried on return.
            UIApplication.shared.endBackgroundTask(identifier)
        }
        return identifier.rawValue
        #else
        return 0
        #endif
    }

    func endBackgroundWork(_ token: Int) {
        #if canImport(UIKit)
        let identifier = UIBackgroundTaskIdentifier(rawValue: token)
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
        #endif
    }
}
