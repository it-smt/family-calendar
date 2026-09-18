import FamilyCalendarKit
import SwiftUI
import UIKit

/// The one thing SwiftUI cannot do on its own: remote notifications.
///
/// A background push wakes the app, which syncs and reschedules its alerts. It
/// carries no data — putting the change in the notification would make delivery
/// part of the protocol, and APNs makes no promise of delivery.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set once the environment exists. Until then a push has nothing to sync
    /// with, and nothing is lost by ignoring it.
    static let shared = AppDelegate()

    var environment: AppEnvironment?
    var pushRegistration: PushRegistration?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { [pushRegistration] in
            await pushRegistration?.register(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // Simulators and devices without a push entitlement land here. The app
        // works; it just finds out about changes a little later.
        Log.auth.debug("no remote notifications: \(error.localizedDescription, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification payload: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let environment else { return .noData }

        // The whole handler: pull, then reschedule. The system gives a
        // background app a few seconds, which is ample for a page of changes
        // and nowhere near enough to do anything clever.
        await environment.syncFromBackground()
        return .newData
    }
}
