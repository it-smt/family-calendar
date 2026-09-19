import Foundation

/// The one timestamp format the whole system speaks.
///
/// RFC 3339 with milliseconds, always UTC. The same string is what Postgres
/// hands back in a change payload, so a value copied between the two databases
/// needs no conversion — and last-write-wins keeps sub-second resolution, which
/// it would lose if timestamps were truncated to whole seconds.
///
/// Built on `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the
/// format style is a Sendable value, so these can be shared constants. The
/// formatter is a class, and a shared mutable one is exactly the kind of thing
/// strict concurrency exists to refuse.
public enum Timestamp {
    private static let writer = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let readerWithoutFraction = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )

    public static func string(from date: Date) -> String {
        writer.format(date)
    }

    /// Accepts both `...T10:00:00.123Z` and `...T10:00:00Z`: Postgres omits the
    /// fractional part when it happens to be zero.
    ///
    /// And, last, `2026-09-19 10:00:00.000` — the shape SQLite writes a date in
    /// when nobody tells it otherwise. Nothing produces that any more, but rows
    /// written while the encoding strategies were being silently ignored are in
    /// it, and a device should be able to read its own old rows rather than
    /// refuse to open.
    public static func date(from string: String) -> Date? {
        if let parsed = try? writer.parse(string) {
            return parsed
        }
        if let parsed = try? readerWithoutFraction.parse(string) {
            return parsed
        }
        return legacySQLiteDate(from: string)
    }

    private static func legacySQLiteDate(from string: String) -> Date? {
        guard string.count >= 19, string.dropFirst(10).first == " " else { return nil }
        var repaired = string.replacingOccurrences(of: " ", with: "T")
        if !repaired.hasSuffix("Z") { repaired += "Z" }
        if let parsed = try? writer.parse(repaired) {
            return parsed
        }
        return try? readerWithoutFraction.parse(repaired)
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
