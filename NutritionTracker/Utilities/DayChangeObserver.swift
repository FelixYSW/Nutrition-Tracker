import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Publishes the current local calendar day and refreshes it without requiring
/// a relaunch (spec section 14).
///
/// Three triggers, because any one alone leaves a gap:
///  - `NSCalendarDayChanged`  - fires at local midnight while running.
///  - `NSSystemTimeZoneDidChange` - the day can change the instant you land.
///  - foreground return - covers the case where the app was suspended through
///    midnight and never received the day-changed notification.
@MainActor
@Observable
final class DayChangeObserver {

    /// Start of the current local day. Views derive "today" from this, so a
    /// change republishes every dependent view.
    private(set) var currentDayStart: Date

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default, now: Date = .now) {
        self.notificationCenter = notificationCenter
        self.currentDayStart = LocalDay.start(of: now)
        registerObservers()
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    private func registerObservers() {
        var names: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange
        ]
        #if canImport(UIKit)
        names.append(UIApplication.willEnterForegroundNotification)
        names.append(UIApplication.significantTimeChangeNotification)
        #endif

        for name in names {
            let observer = notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // Notifications can arrive off the main thread despite the queue
                // hint in some edge cases, so hop explicitly.
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            observers.append(observer)
        }
    }

    /// Recomputes the current day. Only publishes when the day actually changed,
    /// so a timezone change within the same day does not churn the UI.
    func refresh(now: Date = .now) {
        let newStart = LocalDay.start(of: now)
        if newStart != currentDayStart {
            currentDayStart = newStart
        }
    }

    /// Test seam: lets a unit test drive the rollover without waiting for midnight.
    func forceDay(containing date: Date) {
        currentDayStart = LocalDay.start(of: date)
    }
}
