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

    /// The next version stamp for a row, strictly after the one it replaces.
    ///
    /// Stamps have millisecond resolution, so two edits a moment apart can land
    /// on the same value. Two versions of a row that compare equal are the same
    /// version as far as last-write-wins is concerned: once the first has been
    /// pushed, the server sees the second as a row it already has, applies
    /// nothing, and the edit is gone — locally clean, never delivered. A device
    /// must never produce two different versions of a row with the same stamp.
    public static func strictlyAfter(_ previous: Date, now: Date = Date()) -> Date {
        let candidate = truncatedToMilliseconds(now)
        let floor = truncatedToMilliseconds(previous).addingTimeInterval(0.001)
        return max(candidate, floor)
    }

    /// Rounds down to the resolution the wire format carries, so comparisons
    /// here mean the same thing as comparisons after a round trip.
    public static func truncatedToMilliseconds(_ date: Date) -> Date {
        let interval = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (interval * 1000).rounded(.down) / 1000)
    }
}
