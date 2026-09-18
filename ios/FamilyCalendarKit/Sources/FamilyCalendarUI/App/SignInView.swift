import FamilyCalendarKit
import SwiftUI

/// Registering, or joining with the invite code the other person reads out.
///
/// The one screen in the app that waits for the network, because it has nothing
/// local to work from yet.
public struct SignInView: View {
    let database: AppDatabase
    let credentials: CredentialStore
    let onSignedIn: (AppEnvironment) -> Void

    public init(
        database: AppDatabase,
        credentials: CredentialStore,
        onSignedIn: @escaping (AppEnvironment) -> Void
    ) {
        self.database = database
        self.credentials = credentials
        self.onSignedIn = onSignedIn
    }

    @State private var mode: Mode = .register
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var householdName = "Home"
    @State private var inviteCode = ""
    @State private var isWorking = false
    @State private var problem: String?

    enum Mode: String, CaseIterable {
        case register = "Start a household"
        case join = "Join one"
    }

    public var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("Your name", text: $displayName)
                        .textContentType(.name)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }

                Section {
                    switch mode {
                    case .register:
                        TextField("Household name", text: $householdName)
                    case .join:
                        TextField("Invite code", text: $inviteCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                }

                if let problem {
                    Section {
                        Text(problem).foregroundStyle(.red).font(.callout)
                    }
                }

                Section {
                    Button(mode == .register ? "Create" : "Join") {
                        Task { await submit() }
                    }
                    .disabled(isWorking || !isComplete)
                }
            }
            .navigationTitle("Family calendar")
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView() } }
        }
    }

    private var isComplete: Bool {
        !displayName.isEmpty && !email.isEmpty && password.count >= 8
            && (mode == .register || !inviteCode.isEmpty)
    }

    private func submit() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }

        let api = SyncAPI(baseURL: ServerAddress.url)
        do {
            let session: SyncAPI.Session
            switch mode {
            case .register:
                session = try await api.register(
                    email: email, password: password,
                    displayName: displayName, householdName: householdName
                )
            case .join:
                session = try await api.join(
                    email: email, password: password,
                    displayName: displayName,
                    inviteCode: inviteCode.trimmingCharacters(in: .whitespaces).uppercased()
                )
            }

            guard
                let userID = UUID(uuidString: session.userId),
                let householdID = UUID(uuidString: session.householdId)
            else {
                problem = "The server sent something unexpected."
                return
            }

            await credentials.store(
                session: CredentialStore.Session(
                    token: session.accessToken,
                    userID: userID,
                    householdID: householdID,
                    email: email
                ),
                password: password
            )

            onSignedIn(
                try AppEnvironment(
                    database: database,
                    api: api,
                    credentials: credentials,
                    householdID: householdID,
                    currentUserID: userID
                )
            )
        } catch SyncAPI.Failure.unauthorized {
            problem = "That email and password do not match."
        } catch SyncAPI.Failure.rejected(_, _) {
            problem = mode == .join ? "No household has that code." : "Could not create the household."
        } catch {
            problem = "Could not reach the server."
        }
    }
}
