import FamilyCalendarKit
import FamilyCalendarUI
import SwiftUI

/// The app target: a shell.
///
/// Everything of substance is in the package, so the app is a window and a
/// lifecycle. Add this file to an Xcode iOS target with the App Group
/// entitlement, and point the target at ../FamilyCalendarKit.
@main
struct FamilyCalendarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state: LaunchState = .loading
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            switch state {
            case .loading:
                ProgressView().task { await load() }
            case .signedOut(let database, let credentials):
                SignInView(database: database, credentials: credentials) { environment in
                    environment.start()
                    delegate.environment = environment
                    delegate.pushRegistration = PushRegistration(
                        api: SyncAPI(baseURL: AppServer.url), credentials: credentials
                    )
                    state = .ready(environment)
                }
            case .ready(let environment):
                RootView(environment: environment)
            case .failed(let message):
                ContentUnavailableView("Could not open the calendar", systemImage: "xmark.octagon", description: Text(message))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard case .ready(let environment) = state else { return }
            switch phase {
            case .active:
                environment.start()
            case .background:
                // A sync on the way out, so the other phone does not wait for
                // the app to be opened again — and a fresh schedule, because
                // from here until the next launch the alerts are all there is.
                environment.enteringBackground()
            default:
                break
            }
        }
    }

    enum LaunchState {
        case loading
        case signedOut(AppDatabase, CredentialStore)
        case ready(AppEnvironment)
        case failed(String)
    }

    private func load() async {
        do {
            let database = try AppDatabase.shared()
            let credentials = CredentialStore()

            guard let session = await credentials.session else {
                state = .signedOut(database, credentials)
                return
            }

            let environment = try AppEnvironment(
                database: database,
                api: SyncAPI(baseURL: AppServer.url),
                credentials: credentials,
                householdID: session.householdID,
                currentUserID: session.userID
            )
            environment.start()
            delegate.environment = environment
            delegate.pushRegistration = PushRegistration(
                api: SyncAPI(baseURL: AppServer.url), credentials: credentials
            )
            state = .ready(environment)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Where the app finds the server. One value, because there is one deployment
/// and two people using it.
///
/// Not `Configuration`: GRDB has a type by that name, and this file is one
/// import away from meaning the wrong one.
enum AppServer {
    static let url = URL(string: "http://localhost:8000")!
}
