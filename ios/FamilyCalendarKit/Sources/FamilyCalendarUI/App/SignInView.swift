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
    @State private var server = ServerAddress.current.absoluteString
    @State private var showingServer = false

    /// Три способа оказаться внутри, а не два.
    ///
    /// Вход по почте и паролю долго отсутствовал, и это было не упущением в
    /// мелочи: выйдя из календаря, человек не мог вернуться в него вообще —
    /// оставалось завести новый, то есть пустой. Сервер умел `auth/login` с
    /// самого начала, звать его было некому.
    enum Mode: String, CaseIterable {
        case register = "Создать"
        case join = "По коду"
        case login = "Войти"
    }

    /// Строчка под переключателем: три коротких слова сами по себе не говорят,
    /// чем «по коду» отличается от «войти».
    private var hint: String {
        switch mode {
        case .register: "Новый календарь. Код приглашения появится в настройках."
        case .join: "Первый раз на этом телефоне, по коду из чужих настроек."
        case .login: "Уже был здесь — та же почта и пароль."
        }
    }

    public var body: some View {
        ZStack {
            Theme.HeaderBackground(Theme.Hour.at(Date()).gradient)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    title
                    picker
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    fields
                    serverField
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
            // Имя спрашивают только у того, кого здесь ещё не знают. При входе
            // оно уже на сервере, и предложить набрать его заново — это
            // предложить набрать его неправильно.
            if mode != .login {
                field("Как тебя зовут", text: $displayName) {
                    $0.textContentType(.name)
                }
                Divider().padding(.leading, 14)
            }
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
            case .login:
                EmptyView()
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

    /// Адрес сервера. Свёрнут, пока его не спросили: тому, кто заводит
    /// календарь первым, он обычно уже известен из установки, а второму
    /// человеку его диктуют вместе с кодом приглашения.
    @ViewBuilder
    private var serverField: some View {
        if showingServer {
            VStack(alignment: .leading, spacing: 6) {
                TextField("calendar.example.com", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                Text("Без https:// — допишется само.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .transition(.opacity)
        } else {
            Button {
                withAnimation(.snappy) { showingServer = true }
            } label: {
                Label(
                    ServerAddress.isConfigured
                        ? ServerAddress.current.absoluteString
                        : "Другой сервер",
                    systemImage: "server.rack"
                )
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
            }
        }
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
            Text(mode == .register ? "Создать календарь" : "Войти")
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
        guard !email.isEmpty, password.count >= 8 else { return false }
        switch mode {
        case .register: return !displayName.isEmpty
        case .join: return !displayName.isEmpty && !inviteCode.isEmpty
        case .login: return true
        }
    }

    // MARK: Отправка

    private func submit() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }

        // Адрес запоминается до попытки, а не после: если сервер не ответит,
        // человек будет менять именно его, и набирать заново незачем.
        guard ServerAddress.set(server) else {
            problem = "Это не похоже на адрес сервера."
            showingServer = true
            return
        }

        let api = SyncAPI(baseURL: ServerAddress.current)
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
            case .login:
                session = try await api.login(email: email, password: password)
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
                    displayName: mode == .login ? nil : displayName,
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
            switch mode {
            case .join: problem = "Нет календаря с таким кодом."
            case .register: problem = "Не получилось создать календарь."
            case .login: problem = "Почта и пароль не совпадают."
            }
        } catch {
            problem = "Сервер \(ServerAddress.current.host() ?? "") не отвечает."
            showingServer = true
        }
    }
}
