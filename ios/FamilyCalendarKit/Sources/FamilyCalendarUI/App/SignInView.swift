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
        case register = "Завести календарь"
        case join = "Присоединиться"
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
                    TextField("Как тебя зовут", text: $displayName)
                        .textContentType(.name)
                    TextField("Почта", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    SecureField("Пароль", text: $password)
                        .textContentType(.password)
                }

                Section {
                    switch mode {
                    case .register:
                        TextField("Название календаря", text: $householdName)
                    case .join:
                        TextField("Код приглашения", text: $inviteCode)
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
                    Button(mode == .register ? "Создать" : "Войти") {
                        Task { await submit() }
                    }
                    .disabled(isWorking || !isComplete)
                }
            }
            .themedScreen()
            .navigationTitle("Семейный календарь")
            .navigationBarTitleDisplayMode(.inline)
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
                problem = "Сервер ответил чем-то неожиданным."
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
            problem = "Почта и пароль не совпадают."
        } catch SyncAPI.Failure.rejected(_, _) {
            problem = mode == .join ? "Нет календаря с таким кодом." : "Не получилось создать календарь."
        } catch {
            problem = "Сервер не отвечает."
        }
    }
}
