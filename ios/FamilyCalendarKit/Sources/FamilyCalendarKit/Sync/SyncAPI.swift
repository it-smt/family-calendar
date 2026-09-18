import Foundation

/// The two endpoints, and the auth calls that get a token for them.
///
/// Nothing above the repository layer sees this type. A view model that could
/// reach the network would eventually wait on it.
public struct SyncAPI: Sendable {
    public struct PullPage: Decodable, Sendable {
        public struct Change: Decodable, Sendable {
            public let seq: Int64?
            public let entityType: String
            public let entityId: String
            public let payload: [String: JSONValue]

            enum CodingKeys: String, CodingKey {
                case seq
                case entityType = "entity_type"
                case entityId = "entity_id"
                case payload
            }
        }

        public let changes: [Change]
        public let cursor: Int64
        public let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case changes, cursor
            case hasMore = "has_more"
        }
    }

    public struct PushResult: Decodable, Sendable {
        public let serverCursor: Int64

        enum CodingKeys: String, CodingKey {
            case serverCursor = "server_cursor"
        }
    }

    public struct Session: Decodable, Sendable {
        public let accessToken: String
        public let userId: String
        public let householdId: String
        public let inviteCode: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case userId = "user_id"
            case householdId = "household_id"
            case inviteCode = "invite_code"
        }
    }

    public enum Failure: Error, Sendable {
        /// The token is gone or no longer valid. The caller re-authenticates
        /// from the Keychain rather than showing a login screen mid-sync.
        case unauthorized
        /// The server refused the payload. Retrying the same bytes will not
        /// help, so the caller must not spin on it.
        case rejected(status: Int, body: String)
        case transport(any Error)
    }

    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Sync

    public func pull(since cursor: Int64, limit: Int, token: String) async throws -> PullPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("sync/pull"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "since", value: String(cursor)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request, as: PullPage.self)
    }

    public func push(_ changes: [ChangePayload], token: String) async throws -> PushResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("sync/push"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = PushBody(
            changes: changes.map { PushBody.Change(entityType: $0.entityType.rawValue, payload: $0.values) }
        )
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, as: PushResult.self)
    }

    private struct PushBody: Encodable {
        struct Change: Encodable {
            let entityType: String
            let payload: [String: JSONValue]

            enum CodingKeys: String, CodingKey {
                case entityType = "entity_type"
                case payload
            }
        }

        let changes: [Change]
    }

    // MARK: Auth

    public func login(email: String, password: String) async throws -> Session {
        try await post("auth/login", body: ["email": email, "password": password])
    }

    public func register(
        email: String, password: String, displayName: String, householdName: String
    ) async throws -> Session {
        try await post(
            "auth/register",
            body: [
                "email": email,
                "password": password,
                "display_name": displayName,
                "household_name": householdName,
            ]
        )
    }

    public func join(
        email: String, password: String, displayName: String, inviteCode: String
    ) async throws -> Session {
        try await post(
            "auth/join",
            body: [
                "email": email,
                "password": password,
                "display_name": displayName,
                "invite_code": inviteCode,
            ]
        )
    }

    private func post<Response: Decodable>(
        _ path: String, body: [String: String]
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, as: Response.self)
    }

    private func send<Response: Decodable>(
        _ request: URLRequest, as type: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try JSONDecoder().decode(Response.self, from: data)
        case 401, 403:
            throw Failure.unauthorized
        default:
            throw Failure.rejected(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }
}
