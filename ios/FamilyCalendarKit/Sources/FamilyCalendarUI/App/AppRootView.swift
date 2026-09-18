import FamilyCalendarKit
import OSLog
import SwiftUI

/// Everything between launching and showing the calendar.
///
/// Lives in the package rather than the app target so that the app target is
/// one file that never has to change — which also means no copy of it can drift
/// out of step with the repository.
public struct AppRootView: View {
    @State private var state: LaunchState = .loading
    @Environment(\.scenePhase) private var scenePhase

    private let delegate: AppDelegate

    public init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    enum LaunchState {
        case loading
        case signedOut(AppDatabase, CredentialStore)
        case ready(AppEnvironment)
        case failed(String)
    }

    public var body: some View {
        content
            .task { await load() }
            .onChange(of: scenePhase) { _, phase in
                guard case .ready(let environment) = state else { return }
                switch phase {
                case .active:
                    environment.start()
                case .background:
                    // A sync on the way out, so the other phone does not wait
                    // for the app to be opened again — and a fresh schedule,
                    // because from here until the next launch the alerts are
                    // all there is.
                    environment.enteringBackground()
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case .signedOut(let database, let credentials):
            SignInView(database: database, credentials: credentials) { environment in
                begin(with: environment, credentials: credentials)
            }
        case .ready(let environment):
            RootView(environment: environment)
        case .failed(let message):
            ContentUnavailableView(
                "Could not open the calendar",
                systemImage: "xmark.octagon",
                description: Text(message)
            )
        }
    }

    private func load() async {
        guard case .loading = state else { return }
        do {
            let database = try AppDatabase.shared()
            let credentials = CredentialStore()

            guard let session = await credentials.session else {
                state = .signedOut(database, credentials)
                return
            }

            begin(
                with: try AppEnvironment(
                    database: database,
                    api: SyncAPI(baseURL: ServerAddress.url),
                    credentials: credentials,
                    householdID: session.householdID,
                    currentUserID: session.userID
                ),
                credentials: credentials
            )
        } catch {
            Log.database.error("could not open: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func begin(with environment: AppEnvironment, credentials: CredentialStore) {
        environment.start()
        delegate.environment = environment
        delegate.pushRegistration = PushRegistration(
            api: SyncAPI(baseURL: ServerAddress.url), credentials: credentials
        )
        state = .ready(environment)
    }
}
