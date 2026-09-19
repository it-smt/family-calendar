import FamilyCalendarKit
import OSLog
import SwiftUI

/// Регистрация или вход по коду приглашения, который второй читает вслух.
///
/// Единственный экран в приложении, который ждёт сеть: работать ему пока не от
/// чего — локальной базы для этого человека ещё нет.
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
    @State private var householdName = "Наш календарь"
    @State private var inviteCode = ""
    @State private var isWorking = false
    @State private var problem: String?

    enum Mode: String, CaseIterable {
        case register = "Завести календарь"
        case join = "Присоединиться"
    }

    public var body: some View {
        ZStack {
            Theme.HeaderBackground(Theme.Hour.at(Date()).gradient)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    title
                    picker
                    fields
                    if let problem { problemCard(problem) }
                    submitButton
                    Text("Дальше приложение работает без сети — сеть нужна только сейчас.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 70)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
    }

    // MARK: Куски

    private var title: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white)
            Text("Семейный календарь")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("На двоих, на двух телефонах")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.bottom, 6)
    }

    private var picker: some View {
        Picker("", selection: $mode.animation(.snappy)) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            field("Как тебя зовут", text: $displayName) {
                $0.textContentType(.name)
            }
            Divider().padding(.leading, 14)
            field("Почта", text: $email) {
                $0.textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Divider().padding(.leading, 14)
            SecureField("Пароль (от 8 знаков)", text: $password)
                .textContentType(.password)
                .padding(14)
            Divider().padding(.leading, 14)

            switch mode {
            case .register:
                field("Название календаря", text: $householdName) { $0 }
            case .join:
                field("Код приглашения", text: $inviteCode) {
                    $0.textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }

    private func field<Styled: View>(
        _ label: String,
        text: Binding<String>,
        modify: (TextField<Text>) -> Styled
    ) -> some View {
        modify(TextField(label, text: text)).padding(14)
    }

    private func problemCard(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.25))
            )
            .transition(.opacity)
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Text(mode == .register ? "Создать" : "Войти")
                .font(.headline)
                .foregroundStyle(Theme.Hour.at(Date()).gradient.from)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white)
                )
        }
        .buttonStyle(.plain)
        .disabled(isWorking || !isComplete)
        .opacity(isComplete ? 1 : 0.5)
    }

    private var isComplete: Bool {
        !displayName.isEmpty && !email.isEmpty && password.count >= 8
            && (mode == .register || !inviteCode.isEmpty)
    }

    // MARK: Отправка

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

            // The household and the person, written locally before anything
            // else — with the names just typed, which the first pull will
            // confirm or correct. Without them the device cannot insert a
            // single row.
            //
            // Not fatal here, and deliberately not part of the `catch` below:
            // the names are a nicety, and `AppEnvironment` writes the same two
            // rows without them. A failure there is the one worth reporting.
            do {
                try LocalIdentity.ensure(
                    in: database,
                    householdID: householdID,
                    userID: userID,
                    householdName: mode == .register ? householdName : nil,
                    displayName: displayName,
                    inviteCode: session.inviteCode
                )
            } catch {
                Log.database.error(
                    "could not write the local identity: \(error.localizedDescription, privacy: .public)"
                )
            }

            let environment = try AppEnvironment(
                database: database,
                api: api,
                credentials: credentials,
                householdID: householdID,
                currentUserID: userID
            )

            // Новому дому — пять категорий, чтобы в первый же день было чем
            // раскрасить список. Присоединившемуся — ничего: он сейчас
            // вытянет те, что уже завёл первый.
            if mode == .register {
                do {
                    try environment.categories.seedStarterCategories(Theme.starterCategories)
                } catch {
                    // Не повод не пускать внутрь: категории заводятся руками.
                    Log.database.error(
                        "could not seed categories: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            onSignedIn(environment)
        } catch SyncAPI.Failure.unauthorized {
            problem = "Почта и пароль не совпадают."
        } catch SyncAPI.Failure.rejected(_, _) {
            problem = mode == .join ? "Нет календаря с таким кодом." : "Не получилось создать календарь."
        } catch {
            problem = "Сервер не отвечает."
        }
    }
}
