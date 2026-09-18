import Foundation

/// The one timestamp format the whole system speaks.
///
/// RFC 3339 with milliseconds, always UTC. The same string is what Postgres
/// hands back in a change payload, so a value copied between the two databases
/// needs no conversion — and last-write-wins keeps sub-second resolution, which
/// it would lose if timestamps were truncated to whole seconds.
public enum Timestamp {
    private static let writer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let readerWithFraction: ISO8601DateFormatter = writer

    private static let readerWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func string(from date: Date) -> String {
        writer.string(from: date)
    }

    /// Accepts both `...T10:00:00.123Z` and `...T10:00:00Z`: Postgres omits the
    /// fractional part when it happens to be zero.
    public static func date(from string: String) -> Date? {
        readerWithFraction.date(from: string) ?? readerWithoutFraction.date(from: string)
    }
}
