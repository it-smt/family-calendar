import Foundation
import Security

/// Holds the session, and knows how to get a new one without asking.
///
/// The token lasts a year, but a year is not forever and a revoked token is
/// immediate. Keeping the password in the Keychain means a token that stops
/// working turns into one silent re-login rather than a login screen appearing
/// over someone's calendar.
public actor CredentialStore {
    public struct Session: Sendable, Codable {
        public var token: String
        public var userID: UUID
        public var householdID: UUID
        public var email: String
    }

    private let service: String
    private var cached: Session?

    public init(service: String = "com.example.familycalendar.session") {
        self.service = service
        self.cached = Self.read(service: service, account: "session")
            .flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    public var token: String? { cached?.token }
    public var session: Session? { cached }

    public func store(session: Session, password: String) {
        cached = session
        if let data = try? JSONEncoder().encode(session) {
            Self.write(data, service: service, account: "session")
        }
        Self.write(Data(password.utf8), service: service, account: "password")
    }

    public func clear() {
        cached = nil
        Self.delete(service: service, account: "session")
        Self.delete(service: service, account: "password")
    }

    /// Exchanges the stored password for a fresh token. Returns false when
    /// there is nothing stored or the server says no — at which point the app
    /// does have to ask, but only then.
    public func refresh(using api: SyncAPI) async -> Bool {
        guard
            let session = cached,
            let passwordData = Self.read(service: service, account: "password"),
            let password = String(data: passwordData, encoding: .utf8)
        else {
            return false
        }

        do {
            let fresh = try await api.login(email: session.email, password: password)
            store(
                session: Session(
                    token: fresh.accessToken,
                    userID: UUID(uuidString: fresh.userId) ?? session.userID,
                    householdID: UUID(uuidString: fresh.householdId) ?? session.householdID,
                    email: session.email
                ),
                password: password
            )
            return true
        } catch {
            Log.auth.error("re-login failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Keychain

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Available after first unlock so a background sync can run while
            // the phone is locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    private static func read(service: String, account: String) -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func write(_ data: Data, service: String, account: String) {
        let request = query(service: service, account: account)
        SecItemDelete(request as CFDictionary)
        var insert = request
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            Log.auth.error("keychain write failed: \(status, privacy: .public)")
        }
    }

    private static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
