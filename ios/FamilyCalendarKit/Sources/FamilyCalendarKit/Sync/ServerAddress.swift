import Foundation
import OSLog

/// Where the app finds the server.
///
/// Not a constant in the source. Two people on two phones reach one deployment
/// by a name that only its owner knows, and `localhost` — which is what this
/// used to be — is reachable from a simulator on the same Mac and from nowhere
/// else. A second phone could never have been pointed anywhere.
///
/// Read in this order:
///
///   1. What was typed on this device, if anything. Kept in the App Group's
///      defaults so the widget's process reads the same answer as the app's.
///   2. `FCServerURL` in the bundle, for a build that knows where it is going.
///   3. `http://localhost:8000`, which is the simulator against `docker
///      compose up` — the first thing anybody does.
public enum ServerAddress {
    static let storageKey = "FCServerURL"

    public static let fallback = URL(string: "http://localhost:8000")!

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppDatabase.appGroupIdentifier) ?? .standard
    }

    public static var current: URL {
        if let stored = defaults.string(forKey: storageKey), let url = parse(stored) {
            return url
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: storageKey) as? String,
            let url = parse(baked)
        {
            return url
        }
        return fallback
    }

    /// Whether this device has been told where to look, or is still on the
    /// default. Worth showing: "нет сети" and "сервер по адресу, которого нет"
    /// look identical from the inside.
    public static var isConfigured: Bool {
        defaults.string(forKey: storageKey).flatMap(parse) != nil
    }

    @discardableResult
    public static func set(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return true
        }
        guard let url = parse(trimmed) else { return false }
        defaults.set(url.absoluteString, forKey: storageKey)
        Log.network.info("server address set to \(url.absoluteString, privacy: .public)")
        return true
    }

    /// Accepts what a person types. "calendar.example.com" is a host, not a
    /// URL, and refusing it would be pedantry — https is what we would have
    /// asked them to type anyway.
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            let url = URL(string: withScheme),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false
        else { return nil }

        // A trailing slash would turn every path into a double one.
        let cleaned = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString
        return URL(string: cleaned)
    }
}
