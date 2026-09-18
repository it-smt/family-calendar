import Foundation
import OSLog

/// Registering for background wake-ups, and handling one.
///
/// The push says "something changed" and carries nothing else. The device wakes,
/// pulls, and reads the change from the database like always — so a
/// notification Apple drops makes this phone late, never wrong. Everything here
/// is an optimisation on top of a system that already works without it.
public actor PushRegistration {
    private let api: SyncAPI
    private let credentials: CredentialStore
    private var registered: String?

    public init(api: SyncAPI, credentials: CredentialStore) {
        self.api = api
        self.credentials = credentials
    }

    /// Called with the token iOS hands over, on every launch.
    public func register(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard token != registered else { return }
        guard let accessToken = await credentials.token else { return }

        do {
            try await api.registerDevice(token: token, accessToken: accessToken)
            registered = token
            Log.auth.info("registered for background wake-ups")
        } catch SyncAPI.Failure.unauthorized {
            if await credentials.refresh(using: api) {
                await register(deviceToken: deviceToken)
            }
        } catch {
            // Not worth surfacing and not worth retrying hard: without it the
            // other phone finds out on the next launch or network change.
            Log.auth.debug("could not register the token: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func forget() {
        registered = nil
    }
}
